// Prints "locked" or "unlocked" for a keychain file without ever showing a password dialog (bundle.sh uses it so
// unattended builds never pop up UI). Usage: swift scripts/keychain_status.swift <path to .keychain-db>
import Security
import Foundation

var kc: SecKeychain?
guard CommandLine.arguments.count == 2, SecKeychainOpen(CommandLine.arguments[1], &kc) == errSecSuccess, let kc else {
    print("missing"); exit(2)
}
var status: SecKeychainStatus = 0
guard SecKeychainGetStatus(kc, &status) == errSecSuccess else { print("missing"); exit(2) }
print(status & SecKeychainStatus(kSecUnlockStateStatus) != 0 ? "unlocked" : "locked")
