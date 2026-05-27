#import "MachOInspector.h"
#include <stdio.h>
#include <string.h>
#include <zlib.h>

// ---- ZIP constants (little-endian on disk) ----
#define ZIP_EOCDR_SIG       0x06054b50u
#define ZIP_CD_SIG          0x02014b50u
#define ZIP_LFH_SIG         0x04034b50u
#define ZIP_METHOD_STORED   0
#define ZIP_METHOD_DEFLATE  8

// ---- Mach-O constants ----
// Fat binaries are stored big-endian on disk. On our little-endian host,
// reading the magic bytes as a host-endian uint32 yields FAT_CIGAM
// (0xbebafeca). FAT_MAGIC (0xcafebabe) appears when the binary was created
// on a big-endian host (rare).
#define M_FAT_MAGIC         0xcafebabeu
#define M_FAT_CIGAM         0xbebafecau
// Thin Mach-O on iOS is little-endian → MH_MAGIC reads natively.
#define M_MH_MAGIC          0xfeedfaceu
#define M_MH_CIGAM          0xcefaedfeu
#define M_MH_MAGIC_64       0xfeedfacfu
#define M_MH_CIGAM_64       0xcffaedfeu
// Load command numbers (mask out LC_REQ_DYLD = 0x80000000 before comparing)
#define LC_ENC_INFO         0x21u
#define LC_ENC_INFO_64      0x2Cu
#define LC_REQ_DYLD_MASK    0x80000000u
// cputype values (from <mach/machine.h>)
#define CPU_TYPE_ARM        12
#define CPU_TYPE_ARM64      0x0100000c

#pragma mark - Byte readers

static inline uint16_t le16(const uint8_t *p) {
    return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}
static inline uint32_t le32(const uint8_t *p) {
    return  (uint32_t)p[0]
         | ((uint32_t)p[1] << 8)
         | ((uint32_t)p[2] << 16)
         | ((uint32_t)p[3] << 24);
}
static inline uint32_t be32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24)
         | ((uint32_t)p[1] << 16)
         | ((uint32_t)p[2] << 8)
         |  (uint32_t)p[3];
}
static inline uint32_t bswap32(uint32_t x) {
    return ((x & 0xFF000000u) >> 24)
         | ((x & 0x00FF0000u) >> 8)
         | ((x & 0x0000FF00u) << 8)
         | ((x & 0x000000FFu) << 24);
}

@implementation MachOInspector

+ (MachOInspectionResult)inspectIPA:(NSString *)ipaPath {
    if (!ipaPath.length) return MachOInspectionResultUnknown;
    FILE *fp = fopen([ipaPath fileSystemRepresentation], "rb");
    if (!fp) return MachOInspectionResultUnknown;
    MachOInspectionResult result;
    @try {
        result = [self inspectFile:fp];
    }
    @catch (NSException *e) {
        NSLog(@"[MachOInspector] caught exception: %@", e);
        result = MachOInspectionResultUnknown;
    }
    fclose(fp);
    return result;
}

#pragma mark - ZIP parsing

+ (MachOInspectionResult)inspectFile:(FILE *)fp {
    if (fseeko(fp, 0, SEEK_END) != 0) return MachOInspectionResultUnknown;
    off_t fileSize = ftello(fp);
    if (fileSize < 22) return MachOInspectionResultUnknown;

    // Read the last ~64 KB to locate the End-Of-Central-Directory Record.
    // EOCDR sits at the very end of the file, possibly followed by a zip
    // comment (max 65535 bytes). 65557 = 22 (EOCDR fixed size) + 65535.
    off_t searchStart = fileSize > (off_t)65557 ? fileSize - 65557 : 0;
    size_t searchLen = (size_t)(fileSize - searchStart);
    NSMutableData *tail = [NSMutableData dataWithLength:searchLen];
    if (!tail) return MachOInspectionResultUnknown;
    if (fseeko(fp, searchStart, SEEK_SET) != 0) return MachOInspectionResultUnknown;
    if (fread(tail.mutableBytes, 1, searchLen, fp) != searchLen) return MachOInspectionResultUnknown;

    const uint8_t *tb = tail.bytes;
    NSInteger eocdr = -1;
    // Scan backwards — comment is usually short or absent, so EOCDR is
    // typically the last 22 bytes of the file.
    for (NSInteger i = (NSInteger)searchLen - 22; i >= 0; i--) {
        if (tb[i] == 0x50 && tb[i+1] == 0x4b && tb[i+2] == 0x05 && tb[i+3] == 0x06) {
            eocdr = i;
            break;
        }
    }
    if (eocdr < 0) return MachOInspectionResultUnknown;

    uint32_t cdSize = le32(tb + eocdr + 12);
    uint32_t cdOff  = le32(tb + eocdr + 16);
    // ZIP64 sentinel — file uses the extended ZIP64 format which has its own
    // EOCDR locator. We don't bother supporting it; .ipas are well under 4 GB.
    if (cdOff == 0xFFFFFFFFu || cdSize == 0xFFFFFFFFu) return MachOInspectionResultUnknown;
    if ((off_t)cdOff + (off_t)cdSize > fileSize) return MachOInspectionResultUnknown;
    if (cdSize > 16 * 1024 * 1024) return MachOInspectionResultUnknown;  // 16 MB sanity cap

    NSMutableData *cd = [NSMutableData dataWithLength:cdSize];
    if (!cd) return MachOInspectionResultUnknown;
    if (fseeko(fp, cdOff, SEEK_SET) != 0) return MachOInspectionResultUnknown;
    if (fread(cd.mutableBytes, 1, cdSize, fp) != cdSize) return MachOInspectionResultUnknown;

    // Walk the central directory. For each entry whose path looks like
    // `Payload/<X>.app/<Y>` with Y containing no dot, treat it as a binary
    // candidate and peek the file data. First candidate that starts with a
    // Mach-O magic is the main executable.
    const uint8_t *cdp = cd.bytes;
    const uint8_t *cdEnd = cdp + cd.length;
    while (cdp + 46 <= cdEnd) {
        if (le32(cdp) != ZIP_CD_SIG) break;
        uint16_t method   = le16(cdp + 10);
        uint32_t compSize = le32(cdp + 20);
        uint16_t fnLen    = le16(cdp + 28);
        uint16_t exLen    = le16(cdp + 30);
        uint16_t cmLen    = le16(cdp + 32);
        uint32_t lhOff    = le32(cdp + 42);

        if (cdp + 46 + (size_t)fnLen + exLen + cmLen > cdEnd) break;
        const uint8_t *fn = cdp + 46;

        if ([self filenameLooksLikeMainBinary:fn length:fnLen]) {
            MachOInspectionResult r = [self peekEntry:fp
                                            lfhOffset:lhOff
                                           compMethod:method
                                             compSize:compSize];
            if (r != MachOInspectionResultUnknown) {
                return r;
            }
            // peekEntry returned Unknown — either it wasn't actually a Mach-O
            // (some other no-extension file in the .app, e.g., a settings
            // resource) or decompression failed. Keep scanning for the real
            // binary.
        }
        cdp += 46 + fnLen + exLen + cmLen;
    }
    return MachOInspectionResultUnknown;
}

// Path shape: "Payload/X.app/Y" where Y has no dot. We allow the basename to
// contain spaces — some games ship binaries with spaces in the name.
+ (BOOL)filenameLooksLikeMainBinary:(const uint8_t *)fn length:(uint16_t)len {
    if (len < 10) return NO;  // "Payload/X.app/Y" minimum is ~13 chars
    if (memcmp(fn, "Payload/", 8) != 0) return NO;
    // Find the .app/ component and last slash
    NSInteger lastSlash = -1;
    NSInteger appSlash = -1;  // slash right after ".app"
    NSInteger slashCount = 0;
    for (NSInteger i = 0; i < (NSInteger)len; i++) {
        if (fn[i] == '/') {
            slashCount++;
            if (i >= 4
                && fn[i-4] == '.' && fn[i-3] == 'a'
                && fn[i-2] == 'p' && fn[i-1] == 'p') {
                appSlash = i;
            }
            lastSlash = i;
        }
    }
    // Need exactly two slashes (Payload/ + X.app/), the second of which is
    // the one right after ".app".
    if (slashCount != 2 || appSlash < 0 || appSlash != lastSlash) return NO;
    // Basename = bytes after last slash. Must be non-empty and contain no dot.
    if (lastSlash + 1 >= (NSInteger)len) return NO;
    for (NSInteger i = lastSlash + 1; i < (NSInteger)len; i++) {
        if (fn[i] == '.') return NO;
    }
    return YES;
}

// Read the first ~32 KB of the ZIP entry pointed to by `lfhOffset`, decompress
// if needed, and verify it starts with a Mach-O magic. Returns the
// Mach-O inspection result, or Unknown if this entry isn't actually a binary.
+ (MachOInspectionResult)peekEntry:(FILE *)fp
                          lfhOffset:(uint32_t)lhOff
                         compMethod:(uint16_t)method
                           compSize:(uint32_t)compSize {
    uint8_t lfh[30];
    if (fseeko(fp, lhOff, SEEK_SET) != 0) return MachOInspectionResultUnknown;
    if (fread(lfh, 1, 30, fp) != 30) return MachOInspectionResultUnknown;
    if (le32(lfh) != ZIP_LFH_SIG) return MachOInspectionResultUnknown;
    uint16_t lfnLen = le16(lfh + 26);
    uint16_t lexLen = le16(lfh + 28);
    off_t dataOff = (off_t)lhOff + 30 + lfnLen + lexLen;

    // 32 KB is plenty for the Mach-O header + load commands. App binaries
    // can be huge (10s of MB) but all the load commands are right at the
    // start, immediately after the header.
    size_t maxRead = MIN((size_t)compSize, (size_t)32768);
    if (maxRead < 28) return MachOInspectionResultUnknown;  // too small to be Mach-O
    NSMutableData *raw = [NSMutableData dataWithLength:maxRead];
    if (!raw) return MachOInspectionResultUnknown;
    if (fseeko(fp, dataOff, SEEK_SET) != 0) return MachOInspectionResultUnknown;
    size_t got = fread(raw.mutableBytes, 1, maxRead, fp);
    if (got == 0) return MachOInspectionResultUnknown;
    raw.length = got;

    NSData *binData = nil;
    if (method == ZIP_METHOD_STORED) {
        binData = raw;
    } else if (method == ZIP_METHOD_DEFLATE) {
        binData = [self inflateRaw:raw maxOutput:32768];
        if (!binData) return MachOInspectionResultUnknown;
    } else {
        return MachOInspectionResultUnknown;  // unknown compression
    }

    if (binData.length < 28) return MachOInspectionResultUnknown;
    uint32_t magic = le32(binData.bytes);
    if (magic != M_FAT_MAGIC && magic != M_FAT_CIGAM
        && magic != M_MH_MAGIC && magic != M_MH_CIGAM
        && magic != M_MH_MAGIC_64 && magic != M_MH_CIGAM_64) {
        return MachOInspectionResultUnknown;  // not a Mach-O — different no-ext file
    }
    return [self inspectMachOBytes:binData];
}

#pragma mark - zlib inflate (raw deflate, no zlib header)

+ (NSData *)inflateRaw:(NSData *)compressed maxOutput:(size_t)maxLen {
    z_stream strm;
    memset(&strm, 0, sizeof(strm));
    // Negative window bits → raw deflate stream (ZIP doesn't include a zlib header).
    if (inflateInit2(&strm, -MAX_WBITS) != Z_OK) return nil;
    NSMutableData *out = [NSMutableData dataWithLength:maxLen];
    if (!out) { inflateEnd(&strm); return nil; }
    strm.next_in = (Bytef *)compressed.bytes;
    strm.avail_in = (uInt)compressed.length;
    strm.next_out = out.mutableBytes;
    strm.avail_out = (uInt)maxLen;
    int ret = inflate(&strm, Z_NO_FLUSH);
    inflateEnd(&strm);
    // Z_OK = needed more output (we hit maxLen — fine, we have the header).
    // Z_STREAM_END = entire entry fit in maxLen — also fine.
    // Anything else = corrupt input.
    if (ret != Z_OK && ret != Z_STREAM_END && ret != Z_BUF_ERROR) return nil;
    out.length = maxLen - strm.avail_out;
    if (out.length < 28) return nil;  // need at least a mach_header
    return out;
}

#pragma mark - Mach-O parsing

+ (MachOInspectionResult)inspectMachOBytes:(NSData *)binData {
    if (binData.length < 28) return MachOInspectionResultUnknown;
    const uint8_t *bytes = binData.bytes;
    size_t len = binData.length;

    uint32_t magic = le32(bytes);
    size_t sliceOff = 0;

    // Fat binary? Pick the ARM (32-bit) slice. Fat headers are big-endian on
    // disk; on our LE host the magic comes back as FAT_CIGAM, but to keep
    // things consistent we always read subsequent fat fields with be32().
    if (magic == M_FAT_MAGIC || magic == M_FAT_CIGAM) {
        if (len < 8) return MachOInspectionResultUnknown;
        uint32_t nfat = be32(bytes + 4);
        if (nfat == 0 || nfat > 16) return MachOInspectionResultUnknown;
        size_t armSlice = 0;
        BOOL haveArm = NO;
        for (uint32_t i = 0; i < nfat; i++) {
            size_t archOff = 8 + (size_t)i * 20;  // fat_arch is 20 bytes
            if (archOff + 20 > len) return MachOInspectionResultUnknown;
            uint32_t cputype = be32(bytes + archOff);
            uint32_t sliceFileOff = be32(bytes + archOff + 8);
            // CPU_TYPE_ARM = 12. Prefer 32-bit ARM. If we don't find one,
            // we'll bail (this app probably isn't installable on iOS 6
            // anyway, but the inspector is conservative and returns Unknown
            // rather than guessing).
            if (cputype == CPU_TYPE_ARM) {
                armSlice = sliceFileOff;
                haveArm = YES;
                break;
            }
        }
        if (!haveArm) return MachOInspectionResultUnknown;
        if (armSlice >= len || armSlice + 4 > len) return MachOInspectionResultUnknown;
        sliceOff = armSlice;
        magic = le32(bytes + sliceOff);
    }

    BOOL is64 = NO;
    BOOL swap = NO;
    if (magic == M_MH_MAGIC) {
        is64 = NO; swap = NO;
    } else if (magic == M_MH_CIGAM) {
        is64 = NO; swap = YES;
    } else if (magic == M_MH_MAGIC_64) {
        is64 = YES; swap = NO;
    } else if (magic == M_MH_CIGAM_64) {
        is64 = YES; swap = YES;
    } else {
        return MachOInspectionResultUnknown;
    }

    size_t headerSize = is64 ? 32 : 28;
    if (sliceOff + headerSize > len) return MachOInspectionResultUnknown;

    // ncmds lives at byte offset 16 within mach_header(_64)
    uint32_t ncmds = le32(bytes + sliceOff + 16);
    if (swap) ncmds = bswap32(ncmds);
    if (ncmds == 0 || ncmds > 1024) return MachOInspectionResultUnknown;

    size_t cmdOff = sliceOff + headerSize;
    for (uint32_t i = 0; i < ncmds; i++) {
        if (cmdOff + 8 > len) return MachOInspectionResultUnknown;
        uint32_t cmd = le32(bytes + cmdOff);
        uint32_t cmdsize = le32(bytes + cmdOff + 4);
        if (swap) { cmd = bswap32(cmd); cmdsize = bswap32(cmdsize); }
        if (cmdsize < 8 || cmdOff + cmdsize > len) return MachOInspectionResultUnknown;

        // LC_REQ_DYLD is a bit-flag that can be set on the cmd value to mark
        // the command as required by the dynamic linker. Strip it before
        // comparing to known command numbers.
        uint32_t cmdMasked = cmd & ~LC_REQ_DYLD_MASK;
        if (cmdMasked == LC_ENC_INFO || cmdMasked == LC_ENC_INFO_64) {
            // cryptid is at byte offset 16 within either variant.
            if (cmdOff + 20 > len) return MachOInspectionResultUnknown;
            uint32_t cryptid = le32(bytes + cmdOff + 16);
            if (swap) cryptid = bswap32(cryptid);
            return cryptid == 0 ? MachOInspectionResultDecrypted
                                : MachOInspectionResultEncrypted;
        }
        cmdOff += cmdsize;
    }
    // Walked all load commands without finding LC_ENCRYPTION_INFO. Homebrew
    // / Adhoc apps fall in this category — they're never FairPlay-protected
    // because they never went through the App Store. Treat as Decrypted.
    return MachOInspectionResultDecrypted;
}

@end
