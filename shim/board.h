#pragma once
/*
 * Per-board constants. Default: RMX1931 (Realme X2 Pro). -DBOARD_VAYU: Xiaomi
 * Poco X3 Pro (vayu), values from its live FDT (2026-11-23, MIUI V14.0.3.0):
 * cont_splash_region@9c000000 (36 MiB), ramoops@a1600000 (8 MiB, record 2 MiB,
 * pmsg 2 MiB at the end), RAM 0x80000000-0xbcc00000 + 0xc0000000-0x200000000.
 */
#ifdef BOARD_VAYU
#define BOARD_NAME		"VAYU"
#define BOARD_SPLASH_BASE	0x9c000000UL
#define BOARD_PSTORE_PMSG	0xa1c00000UL	/* 0xa1600000 + 8 MiB - 2 MiB pmsg */
#define BOARD_RAM_TOP		0x200000000ULL
#define BOARD_VIDEO_MODE	1		/* DSC video panel: scans out by itself, no CTL_START */
#else
#define BOARD_NAME		"RMX1931"
#define BOARD_SPLASH_BASE	0x9d000000UL
#define BOARD_PSTORE_PMSG	0xb7fc0000UL	/* RMX1931 ramoops pmsg-ramoops-0 (2 MiB) */
#define BOARD_RAM_TOP		0x280000000ULL
#define BOARD_VIDEO_MODE	0
#endif
