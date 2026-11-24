/*
 * HotMetal2.bundle: the Metal driver for the Adreno 640 on metal2vulkan + Turnip (boot-arg hotmtl=2 / sweetmtl=2:
 * SweetAccelerator names this bundle and class HotMTL2Device). Metal.framework loads it in every process that asks
 * for a device; -initWithAcceleratorPort: hands back the frontend's device (NativeBridgeMetalFrontend.mm, UniXNU's,
 * over the bridge in bridge/, which drives Turnip, the libvulkan_freedreno.dylib inside this bundle, through the
 * kernel's v2 user client). Which processes get one: backboardd always, others when /var/local/mtl2-clients lists
 * them ("*" = all, "-NAME" excludes NAME); the rest get none, so their frameworks take their CPU paths.
 * Log: /dev/console and /var/local/mtl2.log (when it exists, mode 666), lines "MTL2[pid name]: ...".
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <stdarg.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>
#include <string.h>
#include "NativeBridgeMetalFrontend.h"
#include "bridge/NativeMetalObjects.h"

extern "C" void sm2_logs(const char *s);
static void sm2_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
#include "HotPrimeShaders.h"

extern "C" void sm2_logs(const char *s)
{
	char buf[700];
	int n = snprintf(buf, sizeof(buf), "MTL2[%d %s]: %s\n", getpid(), getprogname(), s);
	if (n > (int)sizeof(buf) - 1)
		n = (int)sizeof(buf) - 1;
	static int console = -2, file = -2;
	if (console == -2) {
		const char *want_console = getenv("HOT_MTL2_CONSOLE");
		if (!want_console)
			want_console = getenv("SWEET_MTL2_CONSOLE");
		console = (want_console && !strcmp(want_console, "1")) ? open("/dev/console", O_WRONLY | O_NOCTTY) : -1;
	}
	if (file == -2)
		file = open("/var/local/mtl2.log", O_WRONLY | O_APPEND);
	if (console >= 0)
		write(console, buf, (size_t)n);
	if (file >= 0)
		write(file, buf, (size_t)n);
}

static void sm2_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void sm2_log(const char *fmt, ...)
{
	char buf[600];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(buf, sizeof(buf), fmt, ap);
	va_end(ap);
	sm2_logs(buf);
}

/*
 * The A640 does not snoop the CPU caches: libSystem's sys_dcache_flush (a no-op where the GPU is coherent) must
 * really clean and invalidate here. User space may (SCTLR_EL1.UCI). This definition wins at link time, for the
 * bridge and the frontend alike (IOSurface imports).
 */
extern "C" void sys_dcache_flush(void *start, size_t len)
{
	uintptr_t a = (uintptr_t)start & ~(uintptr_t)63, end = (uintptr_t)start + len;
	for (; a < end; a += 64)
		__asm__ volatile("dc civac, %0" :: "r"(a) : "memory");
	__asm__ volatile("dsb sy" ::: "memory");
}

/* Metal validation failures abort by default; frameworks with Apple-GPU-only kernels (MPS) report one on any other device. */
__attribute__((constructor)) static void sm2_error_mode(void)
{
	void (*set)(unsigned, unsigned) = (void (*)(unsigned, unsigned))dlsym(RTLD_DEFAULT, "MTLFailureTypeSetErrorModeType");
	for (unsigned t = 0; set && t < 5; t++)
		set(t, 5);	/* 5 = NSLog */
}

/* Selectors the frontend lacks, each logged once (the frontend then raises the usual unrecognised-selector exception) */
static void missing(const char *cls, const char *sel)
{
	static NSMutableSet *seen;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		seen = [NSMutableSet new];
	});
	NSString *k = [NSString stringWithFormat:@"%s %s", cls, sel];
	@synchronized(seen) {
		if ([seen containsObject:k])
			return;
		[seen addObject:k];
	}
	sm2_log("MISSING %s -%s", cls, sel);
}

@interface NBDeviceMethods : NSObject
@end

/*
 * QuartzCore asks for its precompiled pipeline archive (Apple GPU code): none, it builds its pipelines itself.
 * CoreImage / IconServices on iOS 26 also probe stitched & dynamic libraries; refuse cleanly with NSError before
 * _MTLDevice's base implementation schedules MTLCompilerStitchingRequest onto a worker queue and sends private
 * _MTLFunction selectors (-[NBFunction libraryData]) that abort iconservicesagent.
 */
@interface NBDeviceMethods (HotMetal2)
@end
@implementation NBDeviceMethods (HotMetal2)
- (id)newPipelineLibraryWithFilePath:(NSString *)path error:(NSError **)error
{
	(void)path;
	if (error)
		*error = [NSError errorWithDomain:@"HotMetal2" code:1 userInfo:@{ NSLocalizedDescriptionKey : @"no pipeline libraries" }];
	return nil;
}
- (id)newLibraryWithStitchedDescriptor:(id)descriptor error:(NSError **)error
{
	(void)descriptor;
	if (error)
		*error = [NSError errorWithDomain:@"HotMetal2" code:2 userInfo:@{ NSLocalizedDescriptionKey : @"stitched libraries are not supported" }];
	return nil;
}
- (void)newLibraryWithStitchedDescriptor:(id)descriptor completionHandler:(void (^)(id, NSError *))completionHandler
{
	(void)descriptor;
	NSError *err = [NSError errorWithDomain:@"HotMetal2" code:2 userInfo:@{ NSLocalizedDescriptionKey : @"stitched libraries are not supported" }];
	if (completionHandler)
		dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ completionHandler(nil, err); });
}
- (id)newLibraryWithStitchedDescriptorSPI:(id)descriptor error:(NSError **)error
{
	return [self newLibraryWithStitchedDescriptor:descriptor error:error];
}
- (void)newLibraryWithStitchedDescriptorSPI:(id)descriptor completionHandler:(void (^)(id, NSError *))completionHandler
{
	[self newLibraryWithStitchedDescriptor:descriptor completionHandler:completionHandler];
}
- (id)newDynamicLibrary:(id)library error:(NSError **)error
{
	(void)library;
	if (error)
		*error = [NSError errorWithDomain:@"HotMetal2" code:3 userInfo:@{ NSLocalizedDescriptionKey : @"dynamic libraries are not supported" }];
	return nil;
}
- (id)newDynamicLibraryWithURL:(NSURL *)url error:(NSError **)error
{
	(void)url;
	if (error)
		*error = [NSError errorWithDomain:@"HotMetal2" code:3 userInfo:@{ NSLocalizedDescriptionKey : @"dynamic libraries are not supported" }];
	return nil;
}
@end

static bool listed(void)
{
	if (!strcmp(getprogname(), "backboardd"))
		return true;
	FILE *f = fopen("/var/local/mtl2-clients", "r");
	if (!f)
		return false;
	char text[2048] = { 0 };
	size_t n = fread(text, 1, sizeof(text) - 1, f);
	fclose(f);
	text[n] = 0;
	/* names, "*" = all, "-NAME" = never NAME (wins over "*") */
	char *save = NULL;
	bool yes = false;
	for (char *name = strtok_r(text, " ,\t\r\n", &save); name; name = strtok_r(NULL, " ,\t\r\n", &save)) {
		if (name[0] == '-' && !strcmp(name + 1, getprogname()))
			return false;
		if (!strcmp(name, "*") || !strcmp(name, getprogname()))
			yes = true;
	}
	return yes;
}


/*
 * SweetMetal2 (vayu): HOT_MTL2_SELFTEST_B3A8=1 (mtl2-env) makes backboardd test a 'b3a8' IOSurface (RGB10A8_2P_XR10, color plane +
 * alpha plane) through the runtime 20 s after boot, on known bytes: T1 blit to a buffer (copy in, color), T2 a load/store pass
 * (copy in + copy back, both planes), T3 a clear pass (copy back). App text is drawn into such surfaces and samples smeared on
 * the A640 while lavapipe matches Metal. Lines "B3A8 ..." on stderr.
 */
#include <IOSurface/IOSurfaceRef.h>
#include <math.h>
#include "B3A8SelfTestAIR.h"
static void b3a8_num(CFMutableDictionaryRef d, CFStringRef k, long long v)
{
	CFNumberRef n = CFNumberCreate(NULL, kCFNumberLongLongType, &v);
	CFDictionarySetValue(d, k, n);
	CFRelease(n);
}
static void b3a8_test(id<MTLDevice> dev, uint32_t w, uint32_t h)
{
	const uint32_t r0 = (4 * w + 63) & ~63u, r1 = (w + 63) & ~63u;
	const uint32_t s0 = r0 * h, o1 = (s0 + 4095) & ~4095u, s1 = r1 * h, total = (o1 + s1 + 4095) & ~4095u;
	CFMutableDictionaryRef props = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	b3a8_num(props, CFSTR("IOSurfaceWidth"), w);
	b3a8_num(props, CFSTR("IOSurfaceHeight"), h);
	b3a8_num(props, CFSTR("IOSurfacePixelFormat"), 0x62336138);
	b3a8_num(props, CFSTR("IOSurfaceAllocSize"), total);
	CFMutableArrayRef planes = CFArrayCreateMutable(NULL, 2, &kCFTypeArrayCallBacks);
	const uint32_t bpe[2] = { 4, 1 }, row[2] = { r0, r1 }, off[2] = { 0, o1 }, size[2] = { s0, s1 };
	for (int i = 0; i < 2; i++) {
		CFMutableDictionaryRef pl = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
		b3a8_num(pl, CFSTR("IOSurfacePlaneWidth"), w);
		b3a8_num(pl, CFSTR("IOSurfacePlaneHeight"), h);
		b3a8_num(pl, CFSTR("IOSurfacePlaneBytesPerElement"), bpe[i]);
		b3a8_num(pl, CFSTR("IOSurfacePlaneBytesPerRow"), row[i]);
		b3a8_num(pl, CFSTR("IOSurfacePlaneOffset"), off[i]);
		b3a8_num(pl, CFSTR("IOSurfacePlaneSize"), size[i]);
		CFArrayAppendValue(planes, pl);
		CFRelease(pl);
	}
	CFDictionarySetValue(props, CFSTR("IOSurfacePlaneInfo"), planes);
	CFRelease(planes);
	IOSurfaceRef surf = IOSurfaceCreate(props);
	CFRelease(props);
	if (!surf) {
		fprintf(stderr, "B3A8 %ux%u: IOSurfaceCreate failed\n", w, h);
		return;
	}
	IOSurfaceLock(surf, 0, NULL);
	uint8_t *p0 = (uint8_t *)IOSurfaceGetBaseAddressOfPlane(surf, 0), *p1 = (uint8_t *)IOSurfaceGetBaseAddressOfPlane(surf, 1);
	const size_t br0 = IOSurfaceGetBytesPerRowOfPlane(surf, 0), br1 = IOSurfaceGetBytesPerRowOfPlane(surf, 1);
	fprintf(stderr, "B3A8 %ux%u: planes %zu, p0 +%td row %zu, p1 +%td row %zu, alloc %zu\n", w, h, IOSurfaceGetPlaneCount(surf),
		p0 - (uint8_t *)IOSurfaceGetBaseAddress(surf), br0, p1 - (uint8_t *)IOSurfaceGetBaseAddress(surf), br1, IOSurfaceGetAllocSize(surf));
	auto word = [](uint32_t x, uint32_t y) -> uint32_t {
		return ((x * 7 + y * 13 + 100) & 0x3ff) | (((x * 3 + 400) & 0x3ff) << 10) | (((y * 5 + x + 200) & 0x3ff) << 20);
	};
	auto alpha = [](uint32_t x, uint32_t y) -> uint8_t { return (uint8_t)(x * 4 + y * 9 + 1); };
	auto fill = [&] {
		memset(IOSurfaceGetBaseAddress(surf), 0xEE, IOSurfaceGetAllocSize(surf));
		for (uint32_t y = 0; y < h; y++)
			for (uint32_t x = 0; x < w; x++) {
				((uint32_t *)(p0 + y * br0))[x] = word(x, y);
				p1[y * br1 + x] = alpha(x, y);
			}
		sys_dcache_flush(IOSurfaceGetBaseAddress(surf), IOSurfaceGetAllocSize(surf));
	};
	// Compares the planes with the pattern (or a clear's constant words): counts and the first differences.
	auto check = [&](const char *what, bool cleared, uint32_t cw, uint8_t ca) {
		sys_dcache_flush(IOSurfaceGetBaseAddress(surf), IOSurfaceGetAllocSize(surf));
		unsigned bad0 = 0, bad1 = 0, shown = 0;
		if (cleared)
			cw = ((uint32_t *)p0)[0];
		for (uint32_t y = 0; y < h; y++)
			for (uint32_t x = 0; x < w; x++) {
				uint32_t got = ((uint32_t *)(p0 + y * br0))[x] & 0x3fffffff, want = cleared ? (cw & 0x3fffffff) : word(x, y);
				uint8_t ga = p1[y * br1 + x], wa = cleared ? ca : alpha(x, y);
				if (got != want)
					bad0++;
				if (ga != wa)
					bad1++;
				if ((got != want || ga != wa) && shown < 4) {
					shown++;
					fprintf(stderr, "B3A8 %ux%u %s: (%u,%u) word %08x want %08x, alpha %02x want %02x\n", w, h, what, x, y, got, want, ga, wa);
				}
			}
		fprintf(stderr, "B3A8 %ux%u %s: color %u/%u wrong, alpha %u/%u wrong%s first word %08x\n", w, h, what, bad0, w * h, bad1, w * h,
			cleared ? "," : "", ((uint32_t *)p0)[0]);
	};
	IOSurfaceUnlock(surf, 0, NULL);
	MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:(MTLPixelFormat)550 width:w height:h mipmapped:NO];
	td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
	td.storageMode = MTLStorageModeShared;
	id<MTLTexture> tex = [dev newTextureWithDescriptor:td iosurface:surf plane:0];
	id<MTLCommandQueue> q = [dev newCommandQueue];
	if (!tex || !q) {
		fprintf(stderr, "B3A8 %ux%u: texture %p queue %p\n", w, h, tex, q);
		CFRelease(surf);
		return;
	}
	// T1: blit to a buffer (the texture's color words through its shadow's copy in).
	fill();
	id<MTLBuffer> buf = [dev newBufferWithLength:(NSUInteger)4 * w * h options:MTLResourceStorageModeShared];
	id<MTLCommandBuffer> cb = [q commandBuffer];
	id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
	[bl copyFromTexture:tex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, 1)
		   toBuffer:buf destinationOffset:0 destinationBytesPerRow:4 * w destinationBytesPerImage:4 * w * h];
	[bl endEncoding];
	[cb commit];
	[cb waitUntilCompleted];
	{
		const uint32_t *b = (const uint32_t *)buf.contents;
		unsigned bad = 0, shown = 0;
		for (uint32_t y = 0; y < h; y++)
			for (uint32_t x = 0; x < w; x++)
				if (b[y * w + x] != word(x, y) && ++bad && shown++ < 4)
					fprintf(stderr, "B3A8 %ux%u T1: (%u,%u) %08x want %08x\n", w, h, x, y, b[y * w + x], word(x, y));
		fprintf(stderr, "B3A8 %ux%u T1 blit->buffer: %u/%u wrong (status %ld)\n", w, h, bad, w * h, (long)cb.status);
	}
	// T4 kernel read (texture2d<float>::read) and T5 nearest sample at texel centers (fixtures xr2p_read_float, xr_sample_runtime):
	// the texels decoded, color (code - 384) / 510 (red bits 20-29, blue 0-9), alpha / 255.
	fill();
	for (int k = 0; k < 2; k++) {
		static id<MTLLibrary> libs[2];
		if (!libs[k])
			libs[k] = k ? native_bridge_metal_library_with_air(k_xr_samples_bc, sizeof(k_xr_samples_bc))
				    : native_bridge_metal_library_with_air(k_xr_two_planes_bc, sizeof(k_xr_two_planes_bc));
		id<MTLFunction> fn = [libs[k] newFunctionWithName:k ? @"xr_sample_runtime" : @"xr2p_read_float"];
		NSError *err = nil;
		id<MTLComputePipelineState> ps = fn ? [dev newComputePipelineStateWithFunction:fn error:&err] : nil;
		if (!ps) {
			fprintf(stderr, "B3A8 %ux%u T%d: no pipeline (lib %p fn %p): %s\n", w, h, 4 + k, libs[k], fn, err ? err.description.UTF8String : "");
			continue;
		}
		const uint32_t n = w * h;
		id<MTLBuffer> out = [dev newBufferWithLength:(NSUInteger)16 * n options:MTLResourceStorageModeShared];
		memset(out.contents, 0xab, 16 * n);
		id<MTLBuffer> uv = [dev newBufferWithLength:(NSUInteger)8 * n options:MTLResourceStorageModeShared];
		for (uint32_t i = 0; i < n; i++) {
			((float *)uv.contents)[2 * i] = ((i % w) + 0.5f) / w;
			((float *)uv.contents)[2 * i + 1] = ((i / w) + 0.5f) / h;
		}
		MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
		sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterNearest;
		id<MTLSamplerState> smp = [dev newSamplerStateWithDescriptor:sd];
		cb = [q commandBuffer];
		id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
		[ce setComputePipelineState:ps];
		[ce setTexture:tex atIndex:0];
		if (k) {
			[ce setSamplerState:smp atIndex:0];
			[ce setBuffer:uv offset:0 atIndex:0];
			[ce setBuffer:out offset:0 atIndex:1];
			[ce dispatchThreads:MTLSizeMake(n, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
		} else {
			[ce setBuffer:out offset:0 atIndex:0];
			[ce setBytes:&w length:4 atIndex:1];
			[ce dispatchThreads:MTLSizeMake(w, h, 1) threadsPerThreadgroup:MTLSizeMake(32, 32, 1)];
		}
		[ce endEncoding];
		[cb commit];
		[cb waitUntilCompleted];
		const float *o = (const float *)out.contents;
		unsigned bad = 0, shown = 0;
		for (uint32_t i = 0; i < n; i++) {
			const uint32_t x = i % w, y = i / w, c = word(x, y);
			const float want[4] = { ((int)((c >> 20) & 0x3ff) - 384) / 510.f, ((int)((c >> 10) & 0x3ff) - 384) / 510.f,
						((int)(c & 0x3ff) - 384) / 510.f, alpha(x, y) / 255.f };
			bool ok = true;
			for (int j = 0; j < 4; j++)
				ok = ok && fabsf(o[4 * i + j] - want[j]) < 0.003f;
			if (!ok && ++bad && shown++ < 4)
				fprintf(stderr, "B3A8 %ux%u T%d: (%u,%u) got %.4f %.4f %.4f %.4f want %.4f %.4f %.4f %.4f\n", w, h, 4 + k, x, y, o[4 * i],
					o[4 * i + 1], o[4 * i + 2], o[4 * i + 3], want[0], want[1], want[2], want[3]);
		}
		fprintf(stderr, "B3A8 %ux%u T%d %s: %u/%u wrong (status %ld)\n", w, h, 4 + k, k ? "sample" : "kernel read", bad, n, (long)cb.status);
	}
	// T2: a pass that loads and stores, no draws: copy in, then copy back.
	fill();
	MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
	rp.colorAttachments[0].texture = tex;
	rp.colorAttachments[0].loadAction = MTLLoadActionLoad;
	rp.colorAttachments[0].storeAction = MTLStoreActionStore;
	cb = [q commandBuffer];
	[[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
	[cb commit];
	[cb waitUntilCompleted];
	check("T2 load/store", false, 0, 0);
	// T3: a clear pass (0.5, 0.25, 0.75, 0.6): copy back only; alpha 153 everywhere.
	fill();
	rp.colorAttachments[0].loadAction = MTLLoadActionClear;
	rp.colorAttachments[0].clearColor = MTLClearColorMake(0.5, 0.25, 0.75, 0.6);
	cb = [q commandBuffer];
	[[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
	[cb commit];
	[cb waitUntilCompleted];
	check("T3 clear", true, 0, 153);
	// T6 draw (no blend) and T7 draw (source-over) of per-pixel values (fixture rt6_fill_rgba32float) under a scissor,
	// load/store: inside the codes round(510v+384) (T7 blended over the pattern), outside the pattern kept.
	for (int k = 0; k < 2 && h >= 3 && w >= 5; k++) {
		static id<MTLLibrary> lib;
		if (!lib)
			lib = native_bridge_metal_library_with_air(k_rt6_samples_bc, sizeof(k_rt6_samples_bc));
		MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
		pd.vertexFunction = [lib newFunctionWithName:@"rt6_fill_vertex"];
		pd.fragmentFunction = [lib newFunctionWithName:@"rt6_fill_rgba32float"];
		pd.colorAttachments[0].pixelFormat = (MTLPixelFormat)550;
		if (k) {
			pd.colorAttachments[0].blendingEnabled = YES;
			pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
			pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
			pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
			pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
		}
		NSError *err = nil;
		id<MTLRenderPipelineState> ps = (pd.vertexFunction && pd.fragmentFunction) ? [dev newRenderPipelineStateWithDescriptor:pd error:&err] : nil;
		if (!ps) {
			fprintf(stderr, "B3A8 %ux%u T%d: no pipeline (lib %p): %s\n", w, h, 6 + k, lib, err ? err.description.UTF8String : "");
			continue;
		}
		const uint32_t n = w * h, sx = 2, sy = 1, sw = w - 4, sh = h - 2;
		id<MTLBuffer> vals = [dev newBufferWithLength:(NSUInteger)16 * n options:MTLResourceStorageModeShared];
		float *v = (float *)vals.contents;
		for (uint32_t i = 0; i < n; i++) {
			const uint32_t x = i % w, y = i / w;
			v[4 * i] = ((x * 5 + y * 3) % 160) / 100.f - 0.5f;
			v[4 * i + 1] = ((x + 7 * y) % 100) / 100.f;
			v[4 * i + 2] = 0.25f + (x % 4) * 0.1f;
			v[4 * i + 3] = ((x * 11 + y * 7) % 256) / 255.f;
		}
		const uint32_t shape[2] = { w, 1 };
		fill();
		rp.colorAttachments[0].loadAction = MTLLoadActionLoad;
		cb = [q commandBuffer];
		id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
		[re setRenderPipelineState:ps];
		[re setScissorRect:(MTLScissorRect){ sx, sy, sw, sh }];
		[re setFragmentBuffer:vals offset:0 atIndex:0];
		[re setFragmentBytes:shape length:8 atIndex:1];
		[re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
		[re endEncoding];
		[cb commit];
		[cb waitUntilCompleted];
		sys_dcache_flush(IOSurfaceGetBaseAddress(surf), IOSurfaceGetAllocSize(surf));
		unsigned badIn = 0, badOut = 0, shown = 0;
		for (uint32_t y = 0; y < h; y++)
			for (uint32_t x = 0; x < w; x++) {
				const uint32_t i = y * w + x, got = ((uint32_t *)(p0 + y * br0))[x] & 0x3fffffff, c = word(x, y);
				const uint8_t ga = p1[y * br1 + x];
				const bool in = x >= sx && x < sx + sw && y >= sy && y < sy + sh;
				int want[4];
				if (!in) {
					want[0] = (c >> 20) & 0x3ff, want[1] = (c >> 10) & 0x3ff, want[2] = c & 0x3ff, want[3] = alpha(x, y);
				} else {
					const float a = v[4 * i + 3];
					const float d[3] = { ((int)((c >> 20) & 0x3ff) - 384) / 510.f, ((int)((c >> 10) & 0x3ff) - 384) / 510.f,
							     ((int)(c & 0x3ff) - 384) / 510.f };
					for (int j = 0; j < 3; j++) {
						const float o = k ? v[4 * i + j] * a + d[j] * (1 - a) : v[4 * i + j];
						want[j] = (int)lrintf(fminf(fmaxf(510 * o + 384, 0), 1023));
					}
					const float oa = k ? a + alpha(x, y) / 255.f * (1 - a) : a;
					want[3] = (int)lrintf(fminf(fmaxf(oa, 0), 1) * 255);
				}
				const int g[4] = { (int)((got >> 20) & 0x3ff), (int)((got >> 10) & 0x3ff), (int)(got & 0x3ff), ga };
				bool ok = true;
				for (int j = 0; j < 4; j++)
					ok = ok && abs(g[j] - want[j]) <= (k ? 2 : 1);
				if (!ok) {
					in ? badIn++ : badOut++;
					if (shown++ < 6)
						fprintf(stderr, "B3A8 %ux%u T%d: (%u,%u)%s got %d %d %d a%d want %d %d %d a%d\n", w, h, 6 + k, x, y, in ? " in" : " out",
							g[0], g[1], g[2], g[3], want[0], want[1], want[2], want[3]);
				}
			}
		fprintf(stderr, "B3A8 %ux%u T%d draw%s: inside %u/%u wrong, outside %u/%u wrong (status %ld)\n", w, h, 6 + k, k ? " blend" : "", badIn,
			sw * sh, badOut, n - sw * sh, (long)cb.status);
	}
	// T10 two textures over the one surface (as SpringBoard's icon atlas): A draws the left half, B the right, A the left again.
	// All in one command buffer, so each texture's shadow is copied in before the other's draw is copied back: a copy back of a
	// whole image puts the pattern back over the other texture's half.
	if (h >= 3 && w >= 8) {
		static id<MTLLibrary> lib;
		if (!lib)
			lib = native_bridge_metal_library_with_air(k_rt6_samples_bc, sizeof(k_rt6_samples_bc));
		MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
		pd.vertexFunction = [lib newFunctionWithName:@"rt6_fill_vertex"];
		pd.fragmentFunction = [lib newFunctionWithName:@"rt6_fill_rgba32float"];
		pd.colorAttachments[0].pixelFormat = (MTLPixelFormat)550;
		id<MTLRenderPipelineState> ps = (pd.vertexFunction && pd.fragmentFunction) ? [dev newRenderPipelineStateWithDescriptor:pd error:nil] : nil;
		id<MTLTexture> tex2 = [dev newTextureWithDescriptor:td iosurface:surf plane:0];
		const uint32_t n = w * h, half = w / 2;
		id<MTLBuffer> vals = [dev newBufferWithLength:(NSUInteger)16 * n options:MTLResourceStorageModeShared];
		float *v = (float *)vals.contents;
		for (uint32_t i = 0; i < n; i++) {
			v[4 * i] = ((i % w) % 7) / 10.f, v[4 * i + 1] = ((i / w) % 5) / 10.f, v[4 * i + 2] = 0.3f, v[4 * i + 3] = 0.8f;
		}
		const uint32_t shape[2] = { w, 1 };
		fill();
		cb = [q commandBuffer];
		const struct { id<MTLTexture> t; uint32_t x0, x1; } steps[3] = { { tex, 0, half }, { tex2, half, w }, { tex, 0, half } };
		for (int k = 0; ps && tex2 && k < 3; k++) {
			MTLRenderPassDescriptor *rp2 = [MTLRenderPassDescriptor renderPassDescriptor];
			rp2.colorAttachments[0].texture = steps[k].t;
			rp2.colorAttachments[0].loadAction = MTLLoadActionLoad;
			rp2.colorAttachments[0].storeAction = MTLStoreActionStore;
			id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp2];
			[re setRenderPipelineState:ps];
			[re setScissorRect:(MTLScissorRect){ steps[k].x0, 0, steps[k].x1 - steps[k].x0, h }];
			[re setFragmentBuffer:vals offset:0 atIndex:0];
			[re setFragmentBytes:shape length:8 atIndex:1];
			[re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
			[re endEncoding];
		}
		[cb commit];
		[cb waitUntilCompleted];
		sys_dcache_flush(IOSurfaceGetBaseAddress(surf), IOSurfaceGetAllocSize(surf));
		unsigned bad[2] = { 0, 0 }, shown = 0;
		for (uint32_t y = 0; y < h; y++)
			for (uint32_t x = 0; x < w; x++) {
				const uint32_t i = y * w + x, got = ((uint32_t *)(p0 + y * br0))[x] & 0x3fffffff;
				const int g[4] = { (int)((got >> 20) & 0x3ff), (int)((got >> 10) & 0x3ff), (int)(got & 0x3ff), p1[y * br1 + x] };
				int want[4];
				for (int j = 0; j < 3; j++)
					want[j] = (int)lrintf(510 * v[4 * i + j] + 384);
				want[3] = (int)lrintf(v[4 * i + 3] * 255);
				bool ok = true;
				for (int j = 0; j < 4; j++)
					ok = ok && abs(g[j] - want[j]) <= 1;
				if (!ok) {
					bad[x >= half]++;
					if (shown++ < 4)
						fprintf(stderr, "B3A8 %ux%u T10: (%u,%u) got %d %d %d a%d want %d %d %d a%d\n", w, h, x, y, g[0], g[1], g[2], g[3], want[0],
							want[1], want[2], want[3]);
				}
			}
		fprintf(stderr, "B3A8 %ux%u T10 two textures: left %u/%u wrong, right (other texture's) %u/%u wrong (pipeline %p tex2 %p)\n", w, h, bad[0],
			half * h, bad[1], (w - half) * h, ps, tex2);
	}
	// T8 framebuffer fetch (fixture exf_fetch_blend: (src + dst) / 2, src = (x + 0.5, y + 0.5, 1, -0.5)) under a scissor, c0 alone; T9 the same in RenderBox's pass
	// shape (log56: c1 f65 and c2 f550 memoryless, depth/stencil f260 memoryless). Inside: those codes (alpha clamped to [0, 1]), outside kept.
	for (int k = 0; k < 2 && h >= 3 && w >= 5; k++) {
		static id<MTLLibrary> vlib, flib;
		if (!vlib)
			vlib = native_bridge_metal_library_with_air(k_rt6_samples_bc, sizeof(k_rt6_samples_bc));
		if (!flib)
			flib = native_bridge_metal_library_with_air(k_exf_fetch_blend_bc, sizeof(k_exf_fetch_blend_bc));
		MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
		pd.vertexFunction = [vlib newFunctionWithName:@"rt6_fill_vertex"];
		pd.fragmentFunction = [flib newFunctionWithName:@"exf_fetch_blend"];
		pd.colorAttachments[0].pixelFormat = (MTLPixelFormat)550;
		MTLRenderPassDescriptor *fp = [MTLRenderPassDescriptor renderPassDescriptor];
		fp.colorAttachments[0].texture = tex;
		fp.colorAttachments[0].loadAction = MTLLoadActionLoad;
		fp.colorAttachments[0].storeAction = MTLStoreActionStore;
		if (k) {
			pd.colorAttachments[1].pixelFormat = (MTLPixelFormat)65;
			pd.colorAttachments[2].pixelFormat = (MTLPixelFormat)550;
			pd.depthAttachmentPixelFormat = pd.stencilAttachmentPixelFormat = (MTLPixelFormat)260;
			auto ml = [&](MTLPixelFormat f) {
				MTLTextureDescriptor *m = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f width:w height:h mipmapped:NO];
				m.usage = MTLTextureUsageRenderTarget;
				m.storageMode = MTLStorageModeMemoryless;
				return [dev newTextureWithDescriptor:m];
			};
			id<MTLTexture> m1 = ml((MTLPixelFormat)65), m2 = ml((MTLPixelFormat)550), ds = ml((MTLPixelFormat)260);
			fp.colorAttachments[1].texture = m1;
			fp.colorAttachments[1].loadAction = MTLLoadActionClear;
			fp.colorAttachments[1].storeAction = MTLStoreActionDontCare;
			fp.colorAttachments[2].texture = m2;
			fp.colorAttachments[2].loadAction = MTLLoadActionClear;
			fp.colorAttachments[2].storeAction = MTLStoreActionDontCare;
			fp.depthAttachment.texture = ds;
			fp.depthAttachment.loadAction = MTLLoadActionClear;
			fp.depthAttachment.storeAction = MTLStoreActionDontCare;
			fp.stencilAttachment.texture = ds;
			fp.stencilAttachment.loadAction = MTLLoadActionClear;
			fp.stencilAttachment.storeAction = MTLStoreActionDontCare;
			if (!m1 || !m2 || !ds) {
				fprintf(stderr, "B3A8 %ux%u T9: memoryless %p %p %p\n", w, h, m1, m2, ds);
				continue;
			}
		}
		NSError *err = nil;
		id<MTLRenderPipelineState> ps = (pd.vertexFunction && pd.fragmentFunction) ? [dev newRenderPipelineStateWithDescriptor:pd error:&err] : nil;
		if (!ps) {
			fprintf(stderr, "B3A8 %ux%u T%d: no pipeline (lib %p): %s\n", w, h, 8 + k, flib, err ? err.description.UTF8String : "");
			continue;
		}
		const uint32_t n = w * h, sx = 2, sy = 1, sw = w - 4, sh = h - 2;
		fill();
		cb = [q commandBuffer];
		id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:fp];
		[re setRenderPipelineState:ps];
		[re setScissorRect:(MTLScissorRect){ sx, sy, sw, sh }];
		[re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
		[re endEncoding];
		[cb commit];
		[cb waitUntilCompleted];
		sys_dcache_flush(IOSurfaceGetBaseAddress(surf), IOSurfaceGetAllocSize(surf));
		unsigned badIn = 0, badOut = 0, shown = 0;
		for (uint32_t y = 0; y < h; y++)
			for (uint32_t x = 0; x < w; x++) {
				const uint32_t got = ((uint32_t *)(p0 + y * br0))[x] & 0x3fffffff, c = word(x, y);
				const uint8_t ga = p1[y * br1 + x];
				const bool in = x >= sx && x < sx + sw && y >= sy && y < sy + sh;
				const int cc[3] = { (int)((c >> 20) & 0x3ff), (int)((c >> 10) & 0x3ff), (int)(c & 0x3ff) };
				int want[4];
				const float src[4] = { x + 0.5f, y + 0.5f, 1.f, -0.5f };
				for (int j = 0; j < 3; j++)
					want[j] = in ? (int)lrintf(fminf(fmaxf(510 * ((src[j] + (cc[j] - 384) / 510.f) * 0.5f) + 384, 0), 1023)) : cc[j];
				want[3] = in ? (int)lrintf(fminf(fmaxf((src[3] + alpha(x, y) / 255.f) * 0.5f, 0), 1) * 255) : alpha(x, y);
				const int g[4] = { (int)((got >> 20) & 0x3ff), (int)((got >> 10) & 0x3ff), (int)(got & 0x3ff), ga };
				bool ok = true;
				for (int j = 0; j < 4; j++)
					ok = ok && abs(g[j] - want[j]) <= 1;
				if (!ok) {
					in ? badIn++ : badOut++;
					if (shown++ < 6)
						fprintf(stderr, "B3A8 %ux%u T%d: (%u,%u)%s got %d %d %d a%d want %d %d %d a%d\n", w, h, 8 + k, x, y, in ? " in" : " out",
							g[0], g[1], g[2], g[3], want[0], want[1], want[2], want[3]);
				}
			}
		fprintf(stderr, "B3A8 %ux%u T%d fetch%s: inside %u/%u wrong, outside %u/%u wrong (status %ld)\n", w, h, 8 + k,
			k ? " renderbox-shape" : "", badIn, sw * sh, badOut, n - sw * sh, (long)cb.status);
	}
	CFRelease(surf);
}

@interface _MTLDevice : NSObject
@end

@interface HotMTL2Device : _MTLDevice
- (id)initWithAcceleratorPort:(mach_port_t)port;
@end

@implementation HotMTL2Device
- (id)initWithAcceleratorPort:(mach_port_t)port
{
	/* this object is dropped for the frontend's device: initialised, so its -[_MTLDevice dealloc] has queues to release */
	if (!(self = [super init]))
		return nil;
	static id device;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		if (!listed()) {
			sm2_log("not listed (/var/local/mtl2-clients): no Metal device");
			return;
		}
		NSString *bundle = [[NSBundle bundleForClass:[HotMTL2Device class]] bundlePath];
		NSString *turnip = [bundle stringByAppendingPathComponent:@"libvulkan_freedreno.dylib"];
		char cache[256];
		mkdir("/var/local/m2v-cache", 0777);
		chmod("/var/local/m2v-cache", 0777);
		snprintf(cache, sizeof(cache), "/var/local/m2v-cache/%s", getprogname());
		mkdir(cache, 0777);
		if (access(cache, W_OK) != 0) {
			/* a sandboxed process: its own caches directory */
			char dir[256];
			if (confstr(_CS_DARWIN_USER_CACHE_DIR, dir, sizeof(dir) - 8)) {
				snprintf(cache, sizeof(cache), "%sm2v", dir);
				mkdir(cache, 0700);
			}
		}
		/* plain rows everywhere: no Apple framebuffer compression, no 10-bit deep framebuffer */
		setenv("CA_DISABLE_FRAMEBUFFER_COMPRESSION", "1", 1);
		CFPreferencesSetAppValue(CFSTR("CAEnableFramebufferCompression"), kCFBooleanFalse, kCFPreferencesCurrentApplication);
		CFPreferencesSetAppValue(CFSTR("CAEnableIOSurfaceCompression"), kCFBooleanFalse, kCFPreferencesCurrentApplication);
		CFPreferencesSetAppValue(CFSTR("CAEnableDeepFramebuffer"), kCFBooleanFalse, kCFPreferencesCurrentApplication);
		/* debugging: KEY=VALUE lines of /var/local/mtl2-env into this process's environment */
		if (FILE *ef = fopen("/var/local/mtl2-env", "r")) {
			char line[256];
			while (fgets(line, sizeof(line), ef)) {
				line[strcspn(line, "\r\n")] = 0;
				char *eq = strchr(line, '=');
				if (line[0] != '#' && eq) {
					*eq = 0;
					setenv(line, eq + 1, 1);
					sm2_log("env %s=%s", line, eq + 1);
				}
			}
			fclose(ef);
		}
		/* opt-in via HOT_MTL2_LOG_PIPELINES=1: the runtime's VkPipeline makings count into the telemetry (V row) */
		{
			const char *lp = getenv("HOT_MTL2_LOG_PIPELINES");
			if (!lp)
				lp = getenv("SWEET_MTL2_LOG_PIPELINES");
			if (lp && !strcmp(lp, "1"))
				setenv("METAL2VULKAN_LOG_PIPELINES", "1", 0);
		}
		/* Default Adreno 640 GMEM tiling autotune with concurrent binning off (AdrenoMetal@461a8421); overridable via mtl2-env or mtl2-tu-debug */
		setenv("TU_DEBUG", "nocb", 0);
		/* debugging: Turnip options for this process from /var/local/mtl2-tu-debug (TU_DEBUG), its log to /var/local/turnip-<proc>.log */
		{
			char opts[128] = { 0 };
			FILE *f = fopen("/var/local/mtl2-tu-debug", "r");
			if (f) {
				if (fgets(opts, sizeof(opts), f))
					opts[strcspn(opts, "\r\n")] = 0;
				fclose(f);
			}
			if (opts[0]) {
				char path[128];
				snprintf(path, sizeof(path), "/var/local/turnip-%s.log", getprogname());
				setenv("TU_DEBUG", opts, 1);
				setenv("MESA_LOG_FILE", path, 1);
				sm2_log("TU_DEBUG=%s, log %s", opts, path);
			}
		}
		uint64_t registryID = 0;
		IORegistryEntryGetRegistryEntryID(port, &registryID);
		double t0 = CFAbsoluteTimeGetCurrent();
		@try {
			device = native_bridge_metal_open(turnip.UTF8String, cache, registryID, missing);
		} @catch (NSException *e) {
			sm2_log("device: exception %s", e.reason.UTF8String);
			device = nil;
		}
		sm2_log("device %s in %.0f ms (cache %s)%s%s", device ? [[device name] UTF8String] : "refused",
			(CFAbsoluteTimeGetCurrent() - t0) * 1000, cache, device ? "" : ": ", device ? "" : nmb_last_error());
		/*
		 * Extended-range (XR10) formats: the frontend withholds them so backboardd keeps an 8-bit framebuffer; other
		 * processes may render into them (AegirPoster's CAMetalLayer throws "unsupported extended range format" without).
		 */
		if (device && strcmp(getprogname(), "backboardd") != 0)
			class_replaceMethod(object_getClass(device), sel_registerName("supportsExtendedXR10Formats"),
					    imp_implementationWithBlock(^BOOL(id me) { (void)me; return YES; }), "B16@0:8");
		/* image bases, for symbolicating pstack samples (atos -o out/HotMetal2.dSYM -l BASE ADDR) */
		Dl_info self = { 0 }, tu = { 0 };
		dladdr((void *)sm2_logs, &self);
		void *th = dlopen(turnip.UTF8String, RTLD_NOW | RTLD_NOLOAD);
		void *vk = th ? dlsym(th, "vk_icdGetInstanceProcAddr") : NULL;
		if (vk)
			dladdr(vk, &tu);
		sm2_log("images: HotMetal2 %p, libvulkan_freedreno %p", self.dli_fbase, tu.dli_fbase);
		/* SweetMetal2 (vayu): HOT_MTL2_STDERR_CONSOLE=NAME (or 1: every process) sends this process's stderr to the console,
		 * so apps' m2v logs (passes, surfaces) reach the kernel log as daemons' do. */
		{
			const char *v = getenv("HOT_MTL2_STDERR_CONSOLE");
			if (v && (!strcmp(v, "1") || !strcmp(v, getprogname()))) {
				int fd = open("/dev/console", O_WRONLY | O_NOCTTY);
				if (fd >= 0) {
					dup2(fd, 2);
					close(fd);
					fprintf(stderr, "|%s| stderr to console (pid %d)\n", getprogname(), getpid());
				}
			}
		}
		/* backboardd: idle background shader priming (+90 s, QOS_CLASS_BACKGROUND) + optional 10 s telemetry */
		if (device && !strcmp(getprogname(), "backboardd") && getenv("HOT_MTL2_SELFTEST_B3A8")) {
			id<MTLDevice> d = (id<MTLDevice>)device;
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
				@autoreleasepool {
					const uint32_t sizes[][2] = { { 64, 8 }, { 37, 5 }, { 1024, 256 } };
					for (auto &z : sizes)
						b3a8_test(d, z[0], z[1]);
				}
			});
		}
		if (device && !strcmp(getprogname(), "backboardd")) {
			hot_prime_shaders_start((id<MTLDevice>)device, "/var/local/mtl2-primelist", 90);
			dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
				for (;;) {
					sleep(10);
					if (access("/var/local/mtl2-telemetry", F_OK) != 0)
						continue;
					static char text[8192];
					native_bridge_metal_telemetry(text, sizeof(text));
					int fd = open("/var/local/mtl2.log", O_WRONLY | O_APPEND);
					if (fd >= 0) {
						dprintf(fd, "MTL2[%d %s]: telemetry\n%s", getpid(), getprogname(), text);
						close(fd);
					}
				}
			});
		}
	});
	return device;
}
@end

@interface SweetMTL2Device : HotMTL2Device
@end
@implementation SweetMTL2Device
@end
