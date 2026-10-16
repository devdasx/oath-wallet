"""Host-only preflight regression checks. No simulator or Keychain access."""
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest
from SimulatorAppPreflight import SimulatorAppError, embedded_entitlements, validate_simulator_app


BUNDLE = 'org.oathwallet.keychain-probe'
IDENTITY = 'C5T44SZNQX.' + BUNDLE


def executable(entitlements=None):
    if entitlements is None:
        return struct.pack('<8I', 0xfeedfacf, 0x100000c, 0, 2, 0, 0, 0, 0)
    payload = plistlib.dumps(entitlements)
    header = struct.pack('<8I', 0xfeedfacf, 0x100000c, 0, 2, 1, 152, 0, 0)
    segment = struct.pack('<II16sQQQQIIII', 0x19, 152, b'__TEXT', 0, 4096, 0, 4096, 5, 5, 1, 0)
    section = struct.pack('<16s16sQQIIIIIIII', b'__entitlements', b'__TEXT', 0,
                          len(payload), len(header) + 152, 0, 0, 0, 0, 0, 0, 0)
    return header + segment + section + payload


def universal(parts, wide=False):
    size = 32 if wide else 20
    header = struct.pack('>II', 0xcafebabf if wide else 0xcafebabe, len(parts))
    offset = 8 + size * len(parts)
    for part in parts:
        header += struct.pack('>IIQQII' if wide else '>IIIII',
                              *([0x100000c, 0, offset, len(part), 0, 0] if wide
                                else [0x100000c, 0, offset, len(part), 0]))
        offset += len(part)
    return header + b''.join(parts)


class SimulatorAppPreflightTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='oath-preflight-')
        self.addCleanup(self.directory.cleanup)
        self.app = Path(self.directory.name)
        self.info = {'CFBundleIdentifier': BUNDLE, 'CFBundleExecutable': 'Probe',
                     'CFBundleSupportedPlatforms': ['iPhoneSimulator']}

    def validate(self, binary):
        (self.app / 'Info.plist').write_bytes(plistlib.dumps(self.info))
        (self.app / 'Probe').write_bytes(binary)
        validate_simulator_app(self.app, BUNDLE)

    def testDefaultApplicationIdentityWorksWithoutExplicitKeychainSharing(self):
        self.validate(executable({'application-identifier': IDENTITY}))

    def testExplicitKeychainGroupWorks(self):
        self.validate(executable({'application-identifier': IDENTITY, 'keychain-access-groups': [IDENTITY]}))

    def testMissingIdentityFailsBeforeInstallWithActionableMessage(self):
        for binary in [executable(), executable({})]:
            with self.subTest(binary=binary[:32]):
                with self.assertRaisesRegex(SimulatorAppError, '-34018'):
                    self.validate(binary)

    def testWrongOrUnexpandedIdentityIsRejected(self):
        for identity in [7, 'C5T44SZNQX.other.bundle', '$(AppIdentifierPrefix)' + BUNDLE, '*.' + BUNDLE]:
            with self.subTest(identity=identity):
                with self.assertRaises(SimulatorAppError):
                    self.validate(executable({'application-identifier': identity}))

    def testPhysicalDeviceBuildIsRejected(self):
        for platform in [['iPhoneOS'], [], ['iPhoneSimulator', 'iPhoneOS']]:
            self.info['CFBundleSupportedPlatforms'] = platform
            with self.assertRaisesRegex(SimulatorAppError, 'Simulator build'):
                self.validate(executable({'application-identifier': IDENTITY}))

    def testDifferentBundleIsRejected(self):
        self.info['CFBundleIdentifier'] = 'another.app'
        with self.assertRaisesRegex(SimulatorAppError, 'different bundle'):
            self.validate(executable({'application-identifier': IDENTITY}))

    def testExecutableCannotEscapeApp(self):
        for name in ['', '../Probe', '/tmp/Probe', 8]:
            self.info['CFBundleExecutable'] = name
            with self.assertRaisesRegex(SimulatorAppError, 'executable name'):
                self.validate(executable({'application-identifier': IDENTITY}))

    def testEveryUniversalSliceMustHaveIdentity(self):
        valid = executable({'application-identifier': IDENTITY})
        for wide in [False, True]:
            self.validate(universal([valid, valid], wide))
            with self.assertRaisesRegex(SimulatorAppError, '-34018'):
                self.validate(universal([valid, executable()], wide))

    def testTruncatedInputsFailClosed(self):
        valid = executable({'application-identifier': IDENTITY})
        for count in [0, 3, 7, 31, 33, 100, len(valid)-1]:
            with self.assertRaises(SimulatorAppError):
                embedded_entitlements(valid[:count])
        with self.assertRaises(SimulatorAppError):
            embedded_entitlements(universal([valid])[:-1])

    def testCorruptCommandAndEntitlementDictionaryAreRejected(self):
        valid = bytearray(executable({'application-identifier': IDENTITY}))
        struct.pack_into('<I', valid, 36, 0)
        with self.assertRaises(SimulatorAppError):
            embedded_entitlements(bytes(valid))
        with self.assertRaises(SimulatorAppError):
            embedded_entitlements(executable(['not-a-dictionary']))


if __name__ == '__main__':
    unittest.main()
