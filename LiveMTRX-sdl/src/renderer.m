#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <ImageIO/ImageIO.h>
#import <SDL.h>

#include "renderer.h"
#include "sim.h"

// GPU-side instance layout (must match the Metal shader)
typedef struct {
    float inst_pos[2];   // px
    float inst_size[2];  // px
    uint32_t glyph_index;
    float intensity;
    float color[3];
    float _pad; // pad to 16-byte alignment
} GpuInstance;

typedef struct {
    float screen_size[2];
    float atlas_cell[2];
    uint32_t atlas_cols;
    uint32_t _pad;
} Uniforms;

// Runtime CRT settings (matches shader Settings struct)
typedef struct {
    int32_t shadowMaskMode;
    float curvature;
    float phosphorDecay;
    float time;
    float dotCrawl;
    float colorBleed;
    float jitter;
    float roll;
    float burn_in_strength;
    float tube_age;
    int32_t lutEnabled;
    int32_t lutSize;
    float _pad[1];
} CRTSettings;

// --- Static resources ---
static id<MTLDevice> device = nil;
static id<MTLCommandQueue> queue = nil;
static CAMetalLayer *metalLayer = nil;
static id<MTLRenderPipelineState> glyphPS = nil;
static id<MTLRenderPipelineState> brightPS = nil;
static id<MTLRenderPipelineState> blurHPS = nil;
static id<MTLRenderPipelineState> blurVPS = nil;
static id<MTLRenderPipelineState> phosphorPS = nil;
static id<MTLRenderPipelineState> crtPS = nil;
static id<MTLBuffer> quadVB = nil;
static id<MTLBuffer> instanceBuffer = nil;
static id<MTLBuffer> uniformBuffer = nil;
static id<MTLBuffer> settingsBuffer = nil;
static id<MTLTexture> atlasTexture = nil;
static id<MTLSamplerState> defaultSampler = nil;
static SDL_Window *gWindow = NULL;
static NSUInteger instanceCapacity = 20000;

// HDR render targets
static id<MTLTexture> glyphRT = nil;
static id<MTLTexture> brightRT = nil;
static id<MTLTexture> blurRT_A = nil;
static id<MTLTexture> blurRT_B = nil;
static id<MTLTexture> phosphorRT = nil;
static id<MTLTexture> historyRT = nil;
static id<MTLTexture> lut3d = nil; // optional 3D LUT
static int rtW = 0, rtH = 0;

static int atlasCellW = 16;
static int atlasCellH = 16;
static int atlasCols = 16;
static int atlasW = 256;
static int atlasH = 256;

// Simple vertex data: 6 verts (0..1 in quad space)
static const float quadVerts[] = {
    0.0f, 0.0f,
    1.0f, 0.0f,
    0.0f, 1.0f,

    1.0f, 0.0f,
    1.0f, 1.0f,
    0.0f, 1.0f,
};

// Helpers to locate the metallib next to the binary or inside an app bundle
static NSString* exe_dir(void) {
    uint32_t bufsize = 0;
    _NSGetExecutablePath(NULL, &bufsize);
    char *buf = (char*)malloc((size_t)bufsize);
    if (!buf) return nil;
    if (_NSGetExecutablePath(buf, &bufsize) != 0) {
        free(buf);
        return nil;
    }
    NSString *path = [[NSString stringWithUTF8String:buf] stringByStandardizingPath];
    free(buf);
    return [path stringByDeletingLastPathComponent];
}

static NSString* find_metallib_path(void) {
    // 1) Bundle Resources (when packaged as .app)
    NSString *bundlePath = [[NSBundle mainBundle] pathForResource:@"crt" ofType:@"metallib"];
    if (bundlePath && [[NSFileManager defaultManager] fileExistsAtPath:bundlePath]) {
        return bundlePath;
    }

    // 2) Executable directory (CMake POST_BUILD copy puts it here)
    NSString *exeDir = exe_dir();
    if (exeDir) {
        NSString *exeLocal = [exeDir stringByAppendingPathComponent:@"crt.metallib"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:exeLocal]) {
            return exeLocal;
        }
    }

    // 3) Fallback: project-relative path (useful during development)
    NSString *devPath = @"crt.metallib";
    if ([[NSFileManager defaultManager] fileExistsAtPath:devPath]) return devPath;

    return nil;
}

static id<MTLFunction> must_fn(id<MTLLibrary> lib, NSString *name) {
    id<MTLFunction> fn = [lib newFunctionWithName:name];
    if (!fn) NSLog(@"[LiveMTRX] Missing shader function: %@", name);
    return fn;
}

// create/recreate HDR render targets sized to w,h
static void ensureRenderTargets(int w, int h) {
    if (!device) return;
    if (w == rtW && h == rtH && glyphRT && brightRT && blurRT_A && blurRT_B && phosphorRT && historyRT) return;
    rtW = w; rtH = h;
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:rtW height:rtH mipmapped:NO];
    desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    glyphRT = [device newTextureWithDescriptor:desc];
    brightRT = [device newTextureWithDescriptor:desc];
    blurRT_A = [device newTextureWithDescriptor:desc];
    blurRT_B = [device newTextureWithDescriptor:desc];
    phosphorRT = [device newTextureWithDescriptor:desc];
    historyRT = [device newTextureWithDescriptor:desc];
}

bool renderer_init(SDL_Window *window) {
    gWindow = window;
    device = MTLCreateSystemDefaultDevice();
    if (!device) { NSLog(@"No Metal device"); return false; }
    queue = [device newCommandQueue];

    void *layerPtr = SDL_Metal_GetLayer(window);
    if (!layerPtr) { NSLog(@"SDL_Metal_GetLayer returned NULL"); return false; }
    metalLayer = (__bridge CAMetalLayer *)layerPtr;
    metalLayer.device = device;
    metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    metalLayer.framebufferOnly = NO; // we need shader read on RTs later

    // load precompiled Metal library (crt.metallib)
    NSError *err = nil;
    NSString *metallib = find_metallib_path();
    if (!metallib) {
        NSLog(@"[LiveMTRX] crt.metallib not found. Expected in bundle Resources or next to executable.");
        return false;
    }

    id<MTLLibrary> lib = [device newLibraryWithFile:metallib error:&err];
    if (!lib) {
        NSLog(@"[LiveMTRX] Failed to load metallib at %@: %@", metallib, err);
        return false;
    }
    NSLog(@"[LiveMTRX] Loaded metallib: %@", metallib);

    // glyph pipeline (renders to HDR RT)
    id<MTLFunction> glyphV = must_fn(lib, @"glyph_vert");
    id<MTLFunction> glyphF = must_fn(lib, @"glyph_frag");
    MTLRenderPipelineDescriptor *pdGlyph = [[MTLRenderPipelineDescriptor alloc] init];
    pdGlyph.vertexFunction = glyphV; pdGlyph.fragmentFunction = glyphF;
    pdGlyph.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
    err = nil;
    glyphPS = [device newRenderPipelineStateWithDescriptor:pdGlyph error:&err];
    if (!glyphPS) { NSLog(@"glyph pipeline error: %@", err); return false; }

    // fullscreen pipelines: bright, blurH, blurV -> render to HDR RTs
    id<MTLFunction> fullV = must_fn(lib, @"full_vert");
    id<MTLFunction> brightF = must_fn(lib, @"bright_extract");
    id<MTLFunction> blurHF = must_fn(lib, @"blur_h");
    id<MTLFunction> blurVF = must_fn(lib, @"blur_v");
    id<MTLFunction> phosphorF = must_fn(lib, @"phosphor_blend");
    id<MTLFunction> crtF = must_fn(lib, @"crt_final");

    MTLRenderPipelineDescriptor *pdFull = [[MTLRenderPipelineDescriptor alloc] init];
    pdFull.vertexFunction = fullV; pdFull.fragmentFunction = brightF; pdFull.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
    brightPS = [device newRenderPipelineStateWithDescriptor:pdFull error:&err]; if (!brightPS) { NSLog(@"brightPS err: %@", err); return false; }

    pdFull.fragmentFunction = blurHF; pdFull.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
    blurHPS = [device newRenderPipelineStateWithDescriptor:pdFull error:&err]; if (!blurHPS) { NSLog(@"blurH err: %@", err); return false; }

    pdFull.fragmentFunction = blurVF; pdFull.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
    blurVPS = [device newRenderPipelineStateWithDescriptor:pdFull error:&err]; if (!blurVPS) { NSLog(@"blurV err: %@", err); return false; }

    // phosphor pipeline
    pdFull.fragmentFunction = phosphorF; pdFull.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
    phosphorPS = [device newRenderPipelineStateWithDescriptor:pdFull error:&err]; if (!phosphorPS) { NSLog(@"phosphorPS err: %@", err); return false; }

    // CRT final pipeline renders to drawable (BGRA8)
    MTLRenderPipelineDescriptor *pdCRT = [[MTLRenderPipelineDescriptor alloc] init];
    pdCRT.vertexFunction = fullV; pdCRT.fragmentFunction = crtF; pdCRT.colorAttachments[0].pixelFormat = metalLayer.pixelFormat;
    crtPS = [device newRenderPipelineStateWithDescriptor:pdCRT error:&err]; if (!crtPS) { NSLog(@"crtPS err: %@", err); return false; }

    // buffers
    quadVB = [device newBufferWithBytes:quadVerts length:sizeof(quadVerts) options:MTLResourceStorageModeShared];
    instanceBuffer = [device newBufferWithLength:sizeof(GpuInstance) * instanceCapacity options:MTLResourceStorageModeShared];
    uniformBuffer = [device newBufferWithLength:sizeof(Uniforms) options:MTLResourceStorageModeShared];
    settingsBuffer = [device newBufferWithLength:sizeof(CRTSettings) options:MTLResourceStorageModeShared];

    // sampler
    MTLSamplerDescriptor *sd = [[MTLSamplerDescriptor alloc] init];
    sd.minFilter = MTLSamplerMinMagFilterLinear; sd.magFilter = MTLSamplerMinMagFilterLinear; sd.mipFilter = MTLSamplerMipFilterNotMipmapped;
    defaultSampler = [device newSamplerStateWithDescriptor:sd];

    // atlas
    loadAtlasMetadata();
    atlasTexture = loadAtlasTexture(device);
    if (atlasTexture) { atlasW = (int)atlasTexture.width; atlasH = (int)atlasTexture.height; }

    // try to load optional LUT (3D) at LiveMTRX-sdl/assets/color_lut.ktx or so - optional, skip silently if absent
    // TODO: implement LUT loader if you provide a file format

    return true;
}

void renderer_handle_event(const SDL_Event *e) {
    (void)e; // no-op for now
}

void renderer_draw(SimFrame frame) {
    if (!device || !metalLayer) return;

    // acquire drawable and size
    id<CAMetalDrawable> drawable = [metalLayer nextDrawable];
    if (!drawable) return;
    int winW = (int)drawable.texture.width;
    int winH = (int)drawable.texture.height;

    // ensure RTs sized
    ensureRenderTargets(winW, winH);

    id<MTLCommandBuffer> cmd = [queue commandBuffer];

    // 1) Glyph pass -> glyphRT (HDR)
    MTLRenderPassDescriptor *rpdGlyph = [MTLRenderPassDescriptor renderPassDescriptor];
    rpdGlyph.colorAttachments[0].texture = glyphRT;
    rpdGlyph.colorAttachments[0].loadAction = MTLLoadActionClear;
    rpdGlyph.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,1);
    rpdGlyph.colorAttachments[0].storeAction = MTLStoreActionStore;

    id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:rpdGlyph];
    [enc setRenderPipelineState:glyphPS];

    // Fill instance buffer from frame
    GpuInstance *dst = (GpuInstance *)instanceBuffer.contents;
    int count = 0;
    float cellW = (float)atlasCellW;
    float cellH = (float)atlasCellH;
    for (int i = 0; i < frame.count && count < (int)instanceCapacity; ++i) {
        GlyphInstance gi = frame.instances[i];
        GpuInstance g; memset(&g,0,sizeof(g));
        g.inst_pos[0] = (float)gi.x * cellW; g.inst_pos[1] = (float)gi.y * cellH;
        g.inst_size[0] = cellW; g.inst_size[1] = cellH;
        g.glyph_index = (uint32_t)gi.glyph;
        float intensity = 1.0f;
        switch (gi.tier) { case 0: intensity = 1.4f; break; case 1: intensity = 1.0f; break; case 2: intensity = 0.7f; break; default: intensity = 0.35f; break; }
        g.intensity = intensity;
        g.color[0] = 0.08f; g.color[1] = 1.0f; g.color[2] = 0.25f;
        dst[count++] = g;
    }

    // update uniforms
    Uniforms *u = (Uniforms *)uniformBuffer.contents;
    u->screen_size[0] = (float)winW; u->screen_size[1] = (float)winH;
    if (atlasW > 0 && atlasH > 0) {
        u->atlas_cell[0] = (float)atlasCellW / (float)atlasW;
        u->atlas_cell[1] = (float)atlasCellH / (float)atlasH;
    } else {
        u->atlas_cell[0] = 1.0f / (float)atlasCols; u->atlas_cell[1] = 1.0f / (float)atlasCols;
    }
    u->atlas_cols = (uint32_t)atlasCols;

    [enc setVertexBuffer:quadVB offset:0 atIndex:0];
    [enc setVertexBuffer:instanceBuffer offset:0 atIndex:1];
    [enc setVertexBuffer:uniformBuffer offset:0 atIndex:2];
    if (atlasTexture) [enc setFragmentTexture:atlasTexture atIndex:0];
    if (defaultSampler) [enc setFragmentSamplerState:defaultSampler atIndex:0];

    if (count > 0) {
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6 instanceCount:count];
    }
    [enc endEncoding];

    // 2) Bright extract: glyphRT -> brightRT
    MTLRenderPassDescriptor *rpdBright = [MTLRenderPassDescriptor renderPassDescriptor];
    rpdBright.colorAttachments[0].texture = brightRT; rpdBright.colorAttachments[0].loadAction = MTLLoadActionClear;
    rpdBright.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,1); rpdBright.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> encB = [cmd renderCommandEncoderWithDescriptor:rpdBright];
    [encB setRenderPipelineState:brightPS];
    [encB setVertexBuffer:quadVB offset:0 atIndex:0];
    [encB setVertexBuffer:uniformBuffer offset:0 atIndex:2];
    [encB setFragmentTexture:glyphRT atIndex:0];
    [encB setFragmentSamplerState:defaultSampler atIndex:0];
    [encB drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6 instanceCount:1];
    [encB endEncoding];

    // 3) Blur H: brightRT -> blurRT_A
    MTLRenderPassDescriptor *rpdBlurH = [MTLRenderPassDescriptor renderPassDescriptor];
    rpdBlurH.colorAttachments[0].texture = blurRT_A; rpdBlurH.colorAttachments[0].loadAction = MTLLoadActionClear;
    rpdBlurH.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,1); rpdBlurH.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> encH = [cmd renderCommandEncoderWithDescriptor:rpdBlurH];
    [encH setRenderPipelineState:blurHPS];
    [encH setVertexBuffer:quadVB offset:0 atIndex:0];
    [encH setVertexBuffer:uniformBuffer offset:0 atIndex:2];
    [encH setFragmentTexture:brightRT atIndex:0];
    [encH setFragmentSamplerState:defaultSampler atIndex:0];
    [encH drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6 instanceCount:1];
    [encH endEncoding];

    // 4) Blur V: blurRT_A -> blurRT_B
    MTLRenderPassDescriptor *rpdBlurV = [MTLRenderPassDescriptor renderPassDescriptor];
    rpdBlurV.colorAttachments[0].texture = blurRT_B; rpdBlurV.colorAttachments[0].loadAction = MTLLoadActionClear;
    rpdBlurV.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,1); rpdBlurV.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> encV = [cmd renderCommandEncoderWithDescriptor:rpdBlurV];
    [encV setRenderPipelineState:blurVPS];
    [encV setVertexBuffer:quadVB offset:0 atIndex:0];
    [encV setVertexBuffer:uniformBuffer offset:0 atIndex:2];
    [encV setFragmentTexture:blurRT_A atIndex:0];
    [encV setFragmentSamplerState:defaultSampler atIndex:0];
    [encV drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6 instanceCount:1];
    [encV endEncoding];

    // prepare CRT settings (update time + defaults)
    CRTSettings *s = (CRTSettings *)settingsBuffer.contents;
    memset(s, 0, sizeof(CRTSettings));
    s->shadowMaskMode = 0; // Trinitron by default
    s->curvature = 0.08f;
    s->phosphorDecay = 0.88f;
    s->dotCrawl = 0.05f;
    s->colorBleed = 0.2f;
    s->jitter = 0.0015f;
    s->roll = 0.0f;
    s->burn_in_strength = 0.995f;
    s->tube_age = 0.0f;
    s->lutEnabled = 0;
    s->lutSize = 32;
    // time (seconds)
    s->time = (float)CACurrentMediaTime();

    // 5) Phosphor blend: glyphRT + blurRT_B + historyRT -> phosphorRT
    MTLRenderPassDescriptor *rpdPh = [MTLRenderPassDescriptor renderPassDescriptor];
    rpdPh.colorAttachments[0].texture = phosphorRT; rpdPh.colorAttachments[0].loadAction = MTLLoadActionClear;
    rpdPh.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,1); rpdPh.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> encP = [cmd renderCommandEncoderWithDescriptor:rpdPh];
    [encP setRenderPipelineState:phosphorPS];
    [encP setVertexBuffer:quadVB offset:0 atIndex:0];
    [encP setVertexBuffer:uniformBuffer offset:0 atIndex:2];
    [encP setFragmentTexture:glyphRT atIndex:0];
    [encP setFragmentTexture:blurRT_B atIndex:1];
    [encP setFragmentTexture:historyRT atIndex:2];
    [encP setFragmentSamplerState:defaultSampler atIndex:0];
    [encP setFragmentBuffer:settingsBuffer offset:0 atIndex:3];
    [encP drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6 instanceCount:1];
    [encP endEncoding];

    // swap phosphor/history -> history becomes latest accumulated frame
    id<MTLTexture> tmpRT = historyRT;
    historyRT = phosphorRT;
    phosphorRT = tmpRT;

    // 6) Final CRT composite: sample historyRT (phosphor) + blurRT_B -> drawable
    MTLRenderPassDescriptor *rpdFinal = [MTLRenderPassDescriptor renderPassDescriptor];
    rpdFinal.colorAttachments[0].texture = drawable.texture; rpdFinal.colorAttachments[0].loadAction = MTLLoadActionClear;
    rpdFinal.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,1); rpdFinal.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> encF = [cmd renderCommandEncoderWithDescriptor:rpdFinal];
    [encF setRenderPipelineState:crtPS];
    [encF setVertexBuffer:quadVB offset:0 atIndex:0];
    [encF setVertexBuffer:uniformBuffer offset:0 atIndex:2];
    [encF setFragmentTexture:historyRT atIndex:0];
    [encF setFragmentTexture:blurRT_B atIndex:1];
    [encF setFragmentSamplerState:defaultSampler atIndex:0];
    [encF setFragmentBuffer:settingsBuffer offset:0 atIndex:3];
    [encF drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6 instanceCount:1];
    [encF endEncoding];

    [cmd presentDrawable:drawable];
    [cmd commit];
}

void renderer_shutdown(void) {
    glyphPS = nil; brightPS = nil; blurHPS = nil; blurVPS = nil; phosphorPS = nil; crtPS = nil;
    quadVB = nil; instanceBuffer = nil; uniformBuffer = nil; settingsBuffer = nil; atlasTexture = nil; defaultSampler = nil;
    glyphRT = nil; brightRT = nil; blurRT_A = nil; blurRT_B = nil; phosphorRT = nil; historyRT = nil; lut3d = nil;
    queue = nil; device = nil; metalLayer = nil; gWindow = NULL;
}
