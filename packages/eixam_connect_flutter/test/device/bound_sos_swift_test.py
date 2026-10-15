from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='eixam-bound-swift-') as tmp:
    main=Path(tmp)/'main.swift'
    main.write_text("""import Foundation
let receipt:[UInt8]=[0xE4,1,0x44,0x33,0x22,0x11,7,1,0xA8,0x1A,0x4B,0x59,0,0xC0,0]
assert(BoundSosReceipt.body(receipt)==Array(receipt.dropFirst(8)))
for index in [1,6,7] { var bad=receipt; bad[index]=0; assert(BoundSosReceipt.body(bad)==nil) }
var zero=receipt; for index in 2...5 { zero[index]=0 }; assert(BoundSosReceipt.body(zero)==nil)
for count in 0..<receipt.count { assert(BoundSosReceipt.body(Array(receipt.prefix(count)))==nil) }
let full:[UInt8]=[0xE4,1,0x44,0x33,0x22,0x11,12,1,0xA8,0x1A,0x4B,0x59,0x48,0xCD,0x1B,0x34,0x44,0x28,0,0xC0]
assert(BoundSosReceipt.body(full)?.count==12)
print("PASS: production Swift bound receipt codec vectors")
""")
    binary=Path(tmp)/'bound-receipt'
    subprocess.run(['xcrun','swiftc',str(root/'ios/Classes/BoundSosReceipt.swift'),str(main),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True)
