/*
 * Panel stride test (built with -DSHIM_STRIDETEST), for vayu's DSC video-mode
 * panel. XNU's GPU path switches VIG0 to 4352-byte rows; on vayu the frames
 * stayed slanted although the register read back 4352. Each test below
 * draws text at 4352-byte rows (slanted while the panel still fetches 4320),
 * then applies the change one way. The test whose text turns straight is the
 * way that works. Only display registers are written.
 */
#include <stdint.h>
#include "console.h"
#include "log.h"
#include "sde.h"
#include "util.h"

#define MDP		0x0ae00000UL
#define CTL(n)		(MDP + 0x2000 + 0x200 * (n))
#define CTL_TOP		0x014
#define CTL_FLUSH	0x018
#define CTL_START	0x01c
#define CTL_INTF_ACTIVE	0x0f4
#define VIG0		(MDP + 0x5000)
#define YSTRIDE0	0x24
#define OLD		4320u
#define NEW		4352u
#define HOLD_MS		7000

static uintptr_t fbase;

static void say(const char *t, uint32_t fg)
{
	unsigned l = 0;
	while (t[l])
		l++;
	con_text(t, l, fg);
	con_text("\n", 1, fg);
}


static void page(uint32_t stride, uint32_t bg, const char *title)
{
	con_init(fbase, stride);
	con_clear(bg);
	for (int i = 0; i < 6; i++) {
		say(title, YELLOW);
		say("THIS TEXT SHOULD BE STRAIGHT", WHITE);
		say("||||||||||||||||||||||||||||||||||||||||", WHITE);
	}
}

static uintptr_t active_ctl(void)
{
	for (int i = 0; i < 6; i++)
		if (rd32(CTL(i) + CTL_INTF_ACTIVE))
			return CTL(i);
	return CTL(0);
}

static void apply(int method, uint32_t stride)
{
	uintptr_t c = active_ctl();
	wr32(VIG0 + YSTRIDE0, stride);
	switch (method) {
	case 1:		/* register only */
		break;
	case 2:		/* RMX1931: CTL0 flush VIG0|VIG1 */
		wr32(CTL(0) + CTL_FLUSH, 0x3);
		break;
	case 3:		/* patch 0154: active CTL, VIG0|VIG1 + CTL bit */
		wr32(c + CTL_FLUSH, 0x3 | (1u << 17));
		break;
	case 4:		/* + LM0 and INTF bits */
		wr32(c + CTL_FLUSH, 0x3 | (1u << 6) | (1u << 17) | (1u << 31));
		break;
	case 5:		/* every flush bit */
		wr32(c + CTL_FLUSH, 0xffffffffu);
		break;
	case 6:		/* flush + CTL_START */
		wr32(c + CTL_FLUSH, 0x3 | (1u << 17));
		wr32(c + CTL_START, 1);
		break;
	}
	delay_ms(60);
}

static const char names[][32] = { "", "1 REGISTER ONLY", "2 CTL0 FLUSH 3", "3 FLUSH 3+CTL",
	"4 FLUSH 3+LM+CTL+INTF", "5 FLUSH ALL", "6 FLUSH+START" };

void stridetest_run(void)
{
	char buf[128];
	unsigned n;
	fbase = sde.pipe ? rd32(sde.pipe + 0x14) : FB_SPLASH_BASE;

	/* Page 0: the setup, at the stride ABL left. */
	con_init(fbase, OLD);
	con_clear(BLUE);
	say("STRIDE TEST: note which numbered test turns straight", YELLOW);
	for (int i = 0; i < 6; i++) {
		n = fmt_snprintf(buf, sizeof(buf), "ctl%d top %x flush %x intf %x", i,
				 rd32(CTL(i) + CTL_TOP), rd32(CTL(i) + CTL_FLUSH), rd32(CTL(i) + CTL_INTF_ACTIVE));
		con_text(buf, n, WHITE);
		con_text("\n", 1, WHITE);
	}
	for (int i = 0; i < 4; i++) {
		uintptr_t b = MDP + 0x5000 + 0x2000 * i;
		n = fmt_snprintf(buf, sizeof(buf), "vig%d size %x addr %x stride %x op %x", i,
				 rd32(b), rd32(b + 0x14), rd32(b + 0x24), rd32(b + 0x38));
		con_text(buf, n, WHITE);
		con_text("\n", 1, WHITE);
	}
	for (int i = 0; i < 4; i++) {
		uintptr_t b = MDP + 0x25000 + 0x2000 * i;
		n = fmt_snprintf(buf, sizeof(buf), "dma%d size %x addr %x stride %x", i,
				 rd32(b), rd32(b + 0x14), rd32(b + 0x24));
		con_text(buf, n, WHITE);
		con_text("\n", 1, WHITE);
	}
	delay_ms(12000);

	for (int m = 1; m <= 6; m++) {
		/* Back to ABL's stride, flushed every way that does no harm. */
		wr32(VIG0 + YSTRIDE0, OLD);
		wr32(active_ctl() + CTL_FLUSH, 0x3 | (1u << 17));
		delay_ms(60);
		con_init(fbase, OLD);
		con_clear(0xff303030);
		n = fmt_snprintf(buf, sizeof(buf), "NEXT: TEST %s", names[m]);
		for (int i = 0; i < 4; i++)
			{ con_text(buf, n, YELLOW); con_text("\n", 1, YELLOW); }
		delay_ms(2500);
		/* Text at 4352-byte rows: slanted until the panel fetches 4352. */
		n = fmt_snprintf(buf, sizeof(buf), "TEST %s", names[m]);
		page(NEW, m & 1 ? 0xff002060 : 0xff200040, buf);
		apply(m, NEW);
		delay_ms(HOLD_MS);
	}
	wr32(VIG0 + YSTRIDE0, OLD);
	wr32(active_ctl() + CTL_FLUSH, 0x3 | (1u << 17));
	con_init(fbase, OLD);
	con_clear(0xff004000);
	say("STRIDE TEST done", YELLOW);
	delay_ms(4000);
}
