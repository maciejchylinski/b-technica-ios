# Vendor

## GRDB.swift

Local Swift package pin of [GRDB.swift](https://github.com/groue/GRDB.swift) **v7.6.1**, linked from the Xcode project via SPM (`XCLocalSwiftPackageReference`).

Remote GitHub resolution was unreliable during initial setup; the local package keeps builds deterministic. To refresh:

```bash
curl -L -o /tmp/grdb.tgz \
  https://github.com/groue/GRDB.swift/archive/refs/tags/v7.6.1.tar.gz
rm -rf Vendor/GRDB.swift
mkdir -p Vendor
tar -xzf /tmp/grdb.tgz -C Vendor
mv Vendor/GRDB.swift-7.6.1 Vendor/GRDB.swift
# Drop tests / Xcode project noise, then remove the testTarget from Package.swift
```
