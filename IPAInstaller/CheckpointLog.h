// File-based launch checkpoint log. Survives a crash so we can SSH to the
// device after a launch crash and see exactly how far the app got.
//
// Output path: /var/mobile/Documents/appdrop-launch.log
// Each line: ISO timestamp + checkpoint label.
//
// The whole API is a no-op (best-effort fopen / fwrite) so it can never
// itself crash the launch.

#import <Foundation/Foundation.h>

// Append one checkpoint line. Format: "[timestamp] label". Safe with nil.
void CPLog(NSString *label);

// Truncate the log file (called at the very start of didFinishLaunching so
// each cold launch starts a fresh log; the previous launch's log is what we
// would have wanted, but for now we want to see THIS launch's progress).
void CPLogReset(void);
