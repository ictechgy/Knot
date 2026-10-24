#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Actual enrollment parsers/framing and memory-only identity; no sockets/UI/storage."""
from pathlib import Path
import json, os, subprocess, tempfile
ROOT=Path(__file__).resolve().parents[2]
SWIFT=r'''
import DeskBridgeCore
import Foundation
import Network
import Security
@main struct Checks {
 static func main() throws {
  var count=0
  func expect(_ ok:Bool) { precondition(ok); count += 1 }
  func reject(_ body:() throws -> Void) { do { try body(); fatalError("accepted malformed enrollment") } catch { count += 1 } }
  let prefix:[UInt8]=[0,0,0,11,115,115,104,45,101,100,50,53,53,49,57,0,0,0,32]
  let key="ssh-ed25519 "+Data(prefix+Array(repeating:UInt8(1),count:32)).base64EncodedString()
  let server="ssh-ed25519 "+Data(prefix+Array(repeating:UInt8(2),count:32)).base64EncodedString()
  let request=try SetupExchange.request(clientPublicKey:key,addresses:["192.168.1.20"])
  let pin=String(repeating:"a",count:64), capability=String(repeating:"b",count:64)
  let link=try EnrollmentProtocol.Link(address:"192.168.1.20",port:20000,sessionID:request.requestID,certificateSHA256:pin,capability:capability)
  expect(try EnrollmentProtocol.Link(link.text)==link)
  for bad in [link.text+"?x=1",link.text.replacingOccurrences(of:"192.168.1.20",with:"127.0.0.1"),link.text.replacingOccurrences(of:"192.168.1.20",with:"8.8.8.8"),link.text.replacingOccurrences(of:"192.168.1.20",with:"169.254.1.20"),link.text.replacingOccurrences(of:"20000",with:"020000"),link.text.replacingOccurrences(of:"knot-enroll",with:"https"),link.text+"\n",link.text.replacingOccurrences(of:"#",with:"?x=#")] { reject { _=try EnrollmentProtocol.Link(bad) } }
  var auth:[String:Any]=["kind":"knot.enroll.auth","version":1,"sessionID":request.requestID,"capability":capability]
  try EnrollmentProtocol.authenticate(JSONSerialization.data(withJSONObject:auth),link:link); count += 1
  for entry in [("capability",String(repeating:"c",count:64)),("sessionID",UUID().uuidString.lowercased()),("kind","other")] {
   var bad=auth; bad[entry.0]=entry.1; reject { try EnrollmentProtocol.authenticate(JSONSerialization.data(withJSONObject:bad),link:link) }
  }
  auth["unexpected"]=true; reject { try EnrollmentProtocol.authenticate(JSONSerialization.data(withJSONObject:auth),link:link) }
  for size in [1,2,16384] { let body=Data(repeating:65,count:size); let frame=try EnrollmentProtocol.frame(body); expect(try EnrollmentProtocol.length(frame.prefix(4))==size); expect(frame.dropFirst(4)==body) }
  for body in [Data(),Data(repeating:0,count:16385)] { reject { _=try EnrollmentProtocol.frame(body) } }
  for bytes in [Data(),Data([0,0,0,0]),Data([0,0,64,1]),Data([255,255,255,255])] { reject { _=try EnrollmentProtocol.length(bytes) } }
  var reply:[String:Any]=["kind":"deskbridge.windows-connection","version":1,"requestID":request.requestID,"clientPublicKey":key,"address":"192.168.1.30","port":22,"username":"deskbridge-transfer","serverPublicKey":server]
  _=try EnrollmentProtocol.validateReply(JSONSerialization.data(withJSONObject:reply),request:request,expectedWindowsAddress:"192.168.1.30"); count += 1
  reply["requestID"]=UUID().uuidString.lowercased(); reject { _=try EnrollmentProtocol.validateReply(JSONSerialization.data(withJSONObject:reply),request:request,expectedWindowsAddress:"192.168.1.30") }
  reply["requestID"]=request.requestID
  reject { _=try EnrollmentProtocol.validateReply(JSONSerialization.data(withJSONObject:reply),request:request,expectedWindowsAddress:"192.168.1.31") }
  let validAuth=try JSONSerialization.data(withJSONObject:["kind":"knot.enroll.auth","version":1,"sessionID":request.requestID,"capability":capability])
  let validReply=try JSONSerialization.data(withJSONObject:reply)
  var gate=try EnrollmentProtocol.SessionGate(link:link,request:request,windowsAddress:"192.168.1.30",now:100)
  reject { _=try gate.receive(validReply,now:101) }
  reject { try gate.authorize(validAuth,peer:"192.168.1.31",now:101) }
  try gate.authorize(validAuth,peer:"192.168.1.30",now:101); count += 1
  reject { try gate.authorize(validAuth,peer:"192.168.1.30",now:102) }
  _=try gate.receive(validReply,now:102); count += 1
  reject { _=try gate.receive(validReply,now:103) }
  var late=try EnrollmentProtocol.SessionGate(link:link,request:request,windowsAddress:"192.168.1.30",now:100)
  try late.authorize(validAuth,peer:"192.168.1.30",now:101)
  // Authentication near the original expiry still gets a full, fixed reply
  // budget; ordinary provisioning can safely outlast first-use admission.
  var nearExpiry=try EnrollmentProtocol.SessionGate(link:link,request:request,windowsAddress:"192.168.1.30",now:100)
  try nearExpiry.authorize(validAuth,peer:"192.168.1.30",now:219.5); count += 1
  _=try nearExpiry.receive(validReply,now:819.4); count += 1
  reject { try late.authorize(validAuth,peer:"192.168.1.30",now:650) }
  reject { _=try late.receive(validReply,now:701) }
  // Once observed expired, an earlier supplied timestamp cannot reopen it.
  reject { _=try late.receive(validReply,now:700) }
  var replyBoundary=try EnrollmentProtocol.SessionGate(link:link,request:request,windowsAddress:"192.168.1.30",now:100)
  try replyBoundary.authorize(validAuth,peer:"192.168.1.30",now:219)
  reject { _=try replyBoundary.receive(validReply,now:819) }
  var cancelled=try EnrollmentProtocol.SessionGate(link:link,request:request,windowsAddress:"192.168.1.30",now:100)
  cancelled.cancel(); reject { try cancelled.authorize(validAuth,peer:"192.168.1.30",now:101) }
  reject { _=try cancelled.receive(validReply,now:101) }
  var expired=try EnrollmentProtocol.SessionGate(link:link,request:request,windowsAddress:"192.168.1.30",now:100)
  reject { try expired.authorize(validAuth,peer:"192.168.1.30",now:220) }
  reject { try expired.authorize(validAuth,peer:"192.168.1.30",now:219) }
  for invalidTime in [Double.nan,Double.infinity,-1,99] {
   var invalidClock=try EnrollmentProtocol.SessionGate(link:link,request:request,windowsAddress:"192.168.1.30",now:100)
   reject { try invalidClock.authorize(validAuth,peer:"192.168.1.30",now:invalidTime) }
   reject { try invalidClock.authorize(validAuth,peer:"192.168.1.30",now:101) }
  }
  let expectedPeer=IPv4Address("192.168.1.30")!
  expect(EnrollmentServer.matchesPeer(.ipv4(expectedPeer),expected:expectedPeer))
  expect(!EnrollmentServer.matchesPeer(.ipv4(IPv4Address("192.168.1.31")!),expected:expectedPeer))
  expect(!EnrollmentServer.matchesPeer(.name("192.168.1.30",nil),expected:expectedPeer))
  expect(!EnrollmentServer.matchesPeer(.ipv6(IPv6Address("::ffff:192.168.1.30")!),expected:expectedPeer))
  let first=try EnrollmentIdentity.create(), second=try EnrollmentIdentity.create()
  expect(first.fingerprint.count==64 && first.capability.count==64)
  expect(first.fingerprint != second.fingerprint && first.capability != second.capability)
  var certificate:SecCertificate?; expect(SecIdentityCopyCertificate(first.identity,&certificate)==errSecSuccess && certificate != nil)
  var keyRef:SecKey?; expect(SecIdentityCopyPrivateKey(first.identity,&keyRef)==errSecSuccess && keyRef != nil)
  print("{\"status\":\"passed\",\"checks\":\(count),\"network\":false,\"ui\":false,\"keychain\":false}")
 }
}
'''
def main():
 with tempfile.TemporaryDirectory(prefix='knot-enrollment-synthetic-') as folder:
  temp=Path(folder); os.chmod(temp,0o700)
  def run(argv):
   result=subprocess.run(list(map(str,argv)),cwd=temp,capture_output=True,text=True)
   if result.returncode: raise RuntimeError(result.stdout+result.stderr)
   return result.stdout
  run(['/usr/bin/swiftc','-swift-version','6','-parse-as-library','-emit-library','-static','-emit-module','-module-name','DeskBridgeCore',*sorted((ROOT/'Sources/DeskBridgeCore').rglob('*.swift')),'-emit-module-path',temp/'DeskBridgeCore.swiftmodule','-o',temp/'libDeskBridgeCore.a'])
  (temp/'Checks.swift').write_text(SWIFT)
  run(['/usr/bin/swiftc','-swift-version','6','-parse-as-library','-I',temp,'-L',temp,'-lDeskBridgeCore',ROOT/'Sources/DeskBridgeApp/EnrollmentIdentity.swift',ROOT/'Sources/DeskBridgeApp/EnrollmentServer.swift',temp/'Checks.swift','-o',temp/'Checks'])
  print(run([temp/'Checks']).strip())
if __name__=='__main__': main()
