import AppKit
import CoreImage
import Foundation
import ScreenCaptureKit

struct InkPoint { let x: CGFloat; let y: CGFloat; let pressure: CGFloat }
final class InkStroke {
    let id: String
    let owner: String?
    let color: NSColor
    let colorHex: String
    let width: CGFloat
    let style: String
    var points: [InkPoint]
    init(id: String, owner: String? = nil, colorHex: String = "#253342", width: CGFloat = 4, style: String = "pen", points: [InkPoint] = []) {
        self.id=id; self.owner=owner; self.colorHex=colorHex; self.width=width; self.style=style; self.points=points
        let scanner=Scanner(string:String(colorHex.dropFirst())); var rgb:UInt64=0; scanner.scanHexInt64(&rgb)
        color=NSColor(red:CGFloat((rgb>>16)&255)/255,green:CGFloat((rgb>>8)&255)/255,blue:CGFloat(rgb&255)/255,alpha:1)
    }
    func json() -> [String:Any] { ["id":id,"color":colorHex,"width":width,"style":style,"points":points.map{[$0.x,$0.y,$0.pressure]}] }
    static func parse(_ value:[String:Any]) -> InkStroke? {
        guard let id=value["id"] as? String,let hex=value["color"] as? String,let width=value["width"] as? NSNumber,let raw=value["points"] as? [[NSNumber]] else{return nil}
        return InkStroke(id:id,owner:value["owner"] as? String,colorHex:hex,width:CGFloat(truncating:width),style:value["style"] as? String ?? "pen",points:raw.compactMap{$0.count==3 ? InkPoint(x:CGFloat(truncating:$0[0]),y:CGFloat(truncating:$0[1]),pressure:CGFloat(truncating:$0[2])):nil})
    }
}

final class CanvasView:NSView {
    var strokes:[InkStroke]=[] { didSet { needsDisplay=true } }
    var backgroundImage:NSImage? { didSet { needsDisplay=true } }
    var eraserMode=false
    var overlayMode=false { didSet { needsDisplay=true } }
    var currentColorHex="#253342",currentWidth:CGFloat=4,currentStyle="pen"
    var zoom:CGFloat=1 { didSet { needsDisplay=true } }
    var send:(([String:Any])->Void)?
    private var current:InkStroke?
    override var isFlipped:Bool { true }
    override func draw(_ dirtyRect:NSRect) {
        if !overlayMode { NSColor.white.setFill();bounds.fill() }
        NSGraphicsContext.saveGraphicsState();let transform=NSAffineTransform();transform.translateX(by:bounds.midX,yBy:bounds.midY);transform.scale(by:zoom);transform.translateX(by:-bounds.midX,yBy:-bounds.midY);transform.concat()
        if let image=backgroundImage {
            let scale=min(bounds.width/image.size.width,bounds.height/image.size.height),size=NSSize(width:image.size.width*scale,height:image.size.height*scale)
            image.draw(in:NSRect(x:(bounds.width-size.width)/2,y:(bounds.height-size.height)/2,width:size.width,height:size.height),from:.zero,operation:.sourceOver,fraction:1)
        }
        for stroke in strokes {
            let alpha:CGFloat=stroke.style == "highlighter" ? 0.3:1;stroke.color.withAlphaComponent(alpha).setStroke();stroke.color.withAlphaComponent(alpha).setFill()
            guard let first=stroke.points.first else{continue}
            if stroke.points.count==1 { let d=stroke.width;NSBezierPath(ovalIn:NSRect(x:first.x*bounds.width-d/2,y:first.y*bounds.height-d/2,width:d,height:d)).fill();continue }
            for i in 1..<stroke.points.count { let a=stroke.points[i-1],b=stroke.points[i],path=NSBezierPath();path.lineCapStyle = stroke.style == "marker" ? .square:.round;path.lineJoinStyle = .round;path.lineWidth=stroke.width*(stroke.style == "highlighter" ? 3:1)*(0.4+b.pressure*1.2);path.move(to:NSPoint(x:a.x*bounds.width,y:a.y*bounds.height));path.line(to:NSPoint(x:b.x*bounds.width,y:b.y*bounds.height));path.stroke() }
        }
        NSGraphicsContext.restoreGraphicsState()
    }
    override func mouseDown(with event:NSEvent){if eraserMode{erase(event);return};let s=InkStroke(id:UUID().uuidString,colorHex:currentColorHex,width:currentWidth,style:currentStyle);current=s;strokes.append(s);append(event)}
    override func mouseDragged(with event:NSEvent){if eraserMode{erase(event)}else{append(event)}}
    override func mouseUp(with event:NSEvent){if eraserMode{erase(event);return};append(event);publish();current=nil}
    override func magnify(with event:NSEvent){zoom=max(0.5,min(4,zoom*(1+event.magnification)))}
    private func normalized(_ event:NSEvent)->NSPoint{let p=convert(event.locationInWindow,from:nil);return NSPoint(x:((p.x-bounds.midX)/zoom+bounds.midX)/bounds.width,y:((p.y-bounds.midY)/zoom+bounds.midY)/bounds.height)}
    private func append(_ event:NSEvent){guard let s=current else{return};let p=normalized(event);s.points.append(InkPoint(x:max(0,min(1,p.x)),y:max(0,min(1,p.y)),pressure:event.pressure>0 ? CGFloat(event.pressure):0.5));needsDisplay=true;publish()}
    private func publish(){guard let s=current else{return};send?(["type":"stroke","stroke":s.json()])}
    private func erase(_ event:NSEvent){let p=normalized(event);send?(["type":"erase","point":[max(0,min(1,p.x)),max(0,min(1,p.y))],"radius":0.025/zoom])}
}

final class AppController:NSObject,NSApplicationDelegate {
    let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1200,height:760),styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
    let server=NSTextField(string:"http://localhost:3000"),code=NSTextField(string:""),status=NSTextField(labelWithString:"연결 준비")
    let canvas=CanvasView(),root=NSStackView(),bar=NSStackView();var socket:URLSessionWebSocketTask?;var clientId="";var roomCode="";var normalFrame=NSRect.zero;var screenTimer:Timer?;var captureBusy=false;var annotationWindow:NSWindow?;var annotationCanvas:CanvasView?;var relayProcess:Process?;var tunnelProcess:Process?;var tunnelOutput="";lazy var shareButton=button("Mac 화면 공유",#selector(toggleScreenShare));lazy var externalButton=button("외부 연결",#selector(toggleExternalRelay))
    func applicationDidFinishLaunching(_ notification:Notification){
        window.title="Drawbridge";window.center();window.minSize=NSSize(width:820,height:520)
        root.orientation = .vertical;root.spacing=12;root.edgeInsets=NSEdgeInsets(top:16,left:18,bottom:18,right:18);window.contentView=root
        bar.orientation = .horizontal;bar.spacing=9
        let title=NSTextField(labelWithString:"Drawbridge  ·  MAC");title.font = .boldSystemFont(ofSize:20);title.textColor=NSColor(calibratedRed:0.15,green:0.2,blue:0.26,alpha:1)
        server.placeholderString="서버 주소";server.frame.size.width=250;code.placeholderString="6자리 코드";code.frame.size.width=100
        let create=button("새 보드",#selector(createRoom)),join=button("연결",#selector(joinRoom)),invite=button("QR · 링크",#selector(showInvite)),undo=button("되돌리기",#selector(undo)),pen=button("펜",#selector(usePen)),eraser=button("지우개",#selector(useEraser)),clear=button("전체 지우기",#selector(clearInk)),image=button("이미지",#selector(importImage)),overlay=button("화면 위 필기",#selector(toggleOverlay)),export=button("내보내기",#selector(saveImage)),pdf=button("PDF",#selector(savePDF)),zoomOut=button("−",#selector(zoomOut)),zoomReset=button("100%",#selector(zoomReset)),zoomIn=button("+",#selector(zoomIn))
        let color=NSColorWell();color.color=NSColor(calibratedRed:37/255,green:51/255,blue:66/255,alpha:1);color.target=self;color.action=#selector(changeColor(_:));color.widthAnchor.constraint(equalToConstant:36).isActive=true
        let style=NSPopUpButton();style.addItems(withTitles:["펜","마커","형광펜"]);style.target=self;style.action=#selector(changeStyle(_:))
        let width = NSSlider(value:4,minValue:1,maxValue:16,target:self,action:#selector(changeWidth(_:)));width.widthAnchor.constraint(equalToConstant:70).isActive=true
        bar.addArrangedSubview(title);bar.addArrangedSubview(NSView());bar.addArrangedSubview(server);bar.addArrangedSubview(code);bar.addArrangedSubview(create);bar.addArrangedSubview(join);bar.addArrangedSubview(invite);bar.addArrangedSubview(externalButton);bar.addArrangedSubview(shareButton);bar.addArrangedSubview(undo);bar.addArrangedSubview(pen);bar.addArrangedSubview(eraser);bar.addArrangedSubview(color);bar.addArrangedSubview(style);bar.addArrangedSubview(width);bar.addArrangedSubview(zoomOut);bar.addArrangedSubview(zoomReset);bar.addArrangedSubview(zoomIn);bar.addArrangedSubview(clear);bar.addArrangedSubview(image);bar.addArrangedSubview(overlay);bar.addArrangedSubview(export);bar.addArrangedSubview(pdf);bar.addArrangedSubview(status)
        canvas.wantsLayer=true;canvas.layer?.cornerRadius=12;canvas.layer?.borderWidth=1;canvas.layer?.borderColor=NSColor.lightGray.cgColor
        root.addArrangedSubview(bar);root.addArrangedSubview(canvas);canvas.widthAnchor.constraint(equalTo:root.widthAnchor).isActive=true;canvas.heightAnchor.constraint(greaterThanOrEqualToConstant:500).isActive=true
        canvas.send={ [weak self] message in self?.send(message) };installMenus();window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
    }
    func button(_ title:String,_ action:Selector)->NSButton{let b=NSButton(title:title,target:self,action:action);b.bezelStyle = .rounded;return b}
    func installMenus(){
        let main=NSMenu();let appItem=NSMenuItem();main.addItem(appItem);let appMenu=NSMenu();appMenu.addItem(withTitle:"Drawbridge 종료",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q");appItem.submenu=appMenu
        let editItem=NSMenuItem();main.addItem(editItem);let edit=NSMenu(title:"편집");let undoItem=edit.addItem(withTitle:"되돌리기",action:#selector(undo),keyEquivalent:"z");undoItem.target=self;edit.addItem(.separator());let pen=edit.addItem(withTitle:"펜",action:#selector(usePen),keyEquivalent:"p");pen.target=self;pen.keyEquivalentModifierMask=[.command,.shift];let eraser=edit.addItem(withTitle:"지우개",action:#selector(useEraser),keyEquivalent:"e");eraser.target=self;eraser.keyEquivalentModifierMask=[.command,.shift];editItem.submenu=edit
        let viewItem=NSMenuItem();main.addItem(viewItem);let view=NSMenu(title:"보기");let zoomInItem=view.addItem(withTitle:"확대",action:#selector(zoomIn),keyEquivalent:"+");zoomInItem.target=self;let zoomOutItem=view.addItem(withTitle:"축소",action:#selector(zoomOut),keyEquivalent:"-");zoomOutItem.target=self;let zoomResetItem=view.addItem(withTitle:"100%",action:#selector(zoomReset),keyEquivalent:"0");zoomResetItem.target=self;viewItem.submenu=view;NSApp.mainMenu=main
    }
    var base:String{server.stringValue.trimmingCharacters(in:.whitespacesAndNewlines).replacingOccurrences(of:"/$",with:"",options:.regularExpression)}
    func executable(_ names:[String])->URL?{for name in names{if FileManager.default.isExecutableFile(atPath:name){return URL(fileURLWithPath:name)}};return nil}
    @objc func toggleExternalRelay(){if relayProcess != nil || tunnelProcess != nil{stopExternalRelay();return};startExternalRelay()}
    func startExternalRelay(){
        guard let resources=Bundle.main.resourceURL,FileManager.default.fileExists(atPath:resources.appendingPathComponent("server.js").path)else{status.stringValue="앱에 중계 서버가 없습니다. 다시 설치하세요";return}
        guard let node=executable(["/opt/homebrew/bin/node","/usr/local/bin/node","/usr/bin/node"]),let cloudflared=executable(["/opt/homebrew/bin/cloudflared","/usr/local/bin/cloudflared"])else{status.stringValue="Node.js와 cloudflared를 설치하세요";return}
        let port=Int.random(in:31000...39999),relay=Process();relay.executableURL=node;relay.arguments=[resources.appendingPathComponent("server.js").path];relay.currentDirectoryURL=resources;var environment=ProcessInfo.processInfo.environment;environment["PORT"]=String(port);relay.environment=environment;relay.standardOutput=FileHandle.nullDevice;relay.standardError=FileHandle.nullDevice
        do{try relay.run()}catch{status.stringValue="내장 서버 실행 실패: \(error.localizedDescription)";return};relayProcess=relay
        let tunnel=Process(),pipe=Pipe();tunnel.executableURL=cloudflared;tunnel.arguments=["tunnel","--url","http://127.0.0.1:\(port)","--no-autoupdate"];tunnel.standardOutput=pipe;tunnel.standardError=pipe;tunnelOutput="";pipe.fileHandleForReading.readabilityHandler={ [weak self] handle in guard let self else{return};let data=handle.availableData;guard !data.isEmpty,let chunk=String(data:data,encoding:.utf8)else{return};self.tunnelOutput+=chunk;guard let range=self.tunnelOutput.range(of:"https://[a-z0-9-]+\\.trycloudflare\\.com",options:.regularExpression)else{return};let publicURL=String(self.tunnelOutput[range]);pipe.fileHandleForReading.readabilityHandler=nil;DispatchQueue.main.async{self.server.stringValue=publicURL;self.externalButton.title="외부 중지";self.status.stringValue="외부 주소 준비됨 · 방 생성 중";DispatchQueue.main.asyncAfter(deadline:.now()+1.5){self.createRoom()}}}
        tunnel.terminationHandler={ [weak self] _ in DispatchQueue.main.async{guard let self,self.tunnelProcess != nil else{return};self.status.stringValue="외부 터널이 종료되었습니다";self.stopExternalRelay()}}
        do{try tunnel.run();tunnelProcess=tunnel;externalButton.title="준비 중…";status.stringValue="외부 터널 주소를 발급받는 중"}catch{relay.terminate();relayProcess=nil;status.stringValue="터널 실행 실패: \(error.localizedDescription)"}
    }
    func stopExternalRelay(){let tunnel=tunnelProcess,relay=relayProcess;tunnelProcess=nil;relayProcess=nil;tunnel?.terminate();relay?.terminate();socket?.cancel(with:.goingAway,reason:nil);socket=nil;clientId="";roomCode="";code.stringValue="";server.stringValue="http://localhost:3000";externalButton.title="외부 연결";status.stringValue="외부 연결 종료"}
    @objc func createRoom(){post("/api/create",[:]){ [weak self] result in guard let c=result?["code"] as? String else{return};DispatchQueue.main.async{self?.code.stringValue=c;self?.join(c)}}}
    @objc func joinRoom(){join(code.stringValue)}
    func join(_ room:String){guard room.range(of:"^[0-9]{6}$",options:.regularExpression) != nil else{status.stringValue="코드를 확인하세요";return};post("/api/join",["code":room]){[weak self] result in guard let self,let id=result?["id"] as? String else{return};self.clientId=id;self.roomCode=room;DispatchQueue.main.async{self.connect()}}}
    func post(_ path:String,_ body:[String:Any],completion:@escaping([String:Any]?)->Void){guard let url=URL(string:base+path)else{return};var request=URLRequest(url:url);request.httpMethod="POST";request.setValue("application/json",forHTTPHeaderField:"Content-Type");request.httpBody=try? JSONSerialization.data(withJSONObject:body);URLSession.shared.dataTask(with:request){[weak self] data,response,error in guard let data,let result=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] else{DispatchQueue.main.async{self?.status.stringValue=error?.localizedDescription ?? "서버 연결 실패"};completion(nil);return};if let e=result["error"] as? String{DispatchQueue.main.async{self?.status.stringValue=e};completion(nil)}else{completion(result)}}.resume()}
    func connect(){socket?.cancel(with:.goingAway,reason:nil);guard var parts=URLComponents(string:base)else{return};parts.scheme=parts.scheme=="https" ? "wss":"ws";parts.path="/ws";parts.queryItems=[URLQueryItem(name:"code",value:roomCode),URLQueryItem(name:"id",value:clientId)];guard let url=parts.url else{return};socket=URLSession.shared.webSocketTask(with:url);socket?.resume();status.stringValue="● \(roomCode) 연결됨";receive()}
    func receive(){socket?.receive{[weak self] result in guard let self else{return};if case .success(let message)=result{let data:Data;switch message{case .string(let text):data=Data(text.utf8);case .data(let value):data=value;@unknown default:return};if let json=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any]{DispatchQueue.main.async{self.apply(json)}};self.receive()}else{DispatchQueue.main.async{self.status.stringValue="연결 끊김"}}}}
    func apply(_ message:[String:Any]){if message["type"] as? String == "state",let values=message["strokes"] as? [[String:Any]]{canvas.strokes=values.compactMap(InkStroke.parse);syncAnnotationOverlay()}else if message["type"] as? String == "stroke",let value=message["stroke"] as? [String:Any],let incoming=InkStroke.parse(value){if let i=canvas.strokes.firstIndex(where:{$0.id == incoming.id && $0.owner == incoming.owner}){canvas.strokes[i]=incoming}else{canvas.strokes.append(incoming)};canvas.needsDisplay=true;syncAnnotationOverlay()}else if message["type"] as? String == "background",let value=message["image"] as? String{setBackground(value)}else if message["type"] as? String == "background-clear"{canvas.backgroundImage=nil}}
    func send(_ value:[String:Any]){guard let data=try? JSONSerialization.data(withJSONObject:value),let text=String(data:data,encoding:.utf8)else{return};socket?.send(.string(text)){[weak self] error in if let error{DispatchQueue.main.async{self?.status.stringValue=error.localizedDescription}}}}
    @objc func showInvite(){
        guard roomCode.range(of:"^[0-9]{6}$",options:.regularExpression) != nil else{status.stringValue="먼저 보드를 만들거나 연결하세요";return}
        guard let url=URL(string:base+"/api/network") else{return}
        URLSession.shared.dataTask(with:url){[weak self] data,_,_ in
            guard let self else{return};var address=self.base
            if let data,let object=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],let urls=object["urls"] as? [String],let first=urls.first{address=first}
            var parts=URLComponents();parts.scheme="drawbridge";parts.host="join";parts.queryItems=[URLQueryItem(name:"server",value:address),URLQueryItem(name:"room",value:self.roomCode)]
            guard let link=parts.url?.absoluteString else{return};DispatchQueue.main.async{self.presentInvite(link,address:address)}
        }.resume()
    }
    func presentInvite(_ link:String,address:String){
        let alert=NSAlert();alert.messageText="Android 앱 연결";alert.informativeText="휴대폰 카메라로 QR을 스캔하세요.\n서버: \(address)  ·  방: \(roomCode)"
        if let filter=CIFilter(name:"CIQRCodeGenerator"){filter.setValue(Data(link.utf8),forKey:"inputMessage");filter.setValue("M",forKey:"inputCorrectionLevel");if let output=filter.outputImage?.transformed(by:CGAffineTransform(scaleX:8,y:8)){let rep=NSCIImageRep(ciImage:output);let image=NSImage(size:rep.size);image.addRepresentation(rep);let view=NSImageView(frame:NSRect(x:0,y:0,width:240,height:240));view.image=image;view.imageScaling = .scaleProportionallyUpOrDown;alert.accessoryView=view}}
        alert.addButton(withTitle:"링크 복사");alert.addButton(withTitle:"닫기");if alert.runModal() == .alertFirstButtonReturn{NSPasteboard.general.clearContents();NSPasteboard.general.setString(link,forType:.string);status.stringValue="초대 링크 복사 완료"}
    }
    @objc func usePen(){canvas.eraserMode=false;status.stringValue="펜 모드"}
    @objc func useEraser(){canvas.eraserMode=true;status.stringValue="선 지우개 모드"}
    @objc func undo(){guard socket != nil else{status.stringValue="먼저 보드에 연결하세요";return};send(["type":"undo"]);status.stringValue="마지막 필기 되돌림"}
    @objc func changeColor(_ sender:NSColorWell){let color=sender.color.usingColorSpace(.deviceRGB) ?? sender.color;canvas.currentColorHex=String(format:"#%02X%02X%02X",Int(color.redComponent*255),Int(color.greenComponent*255),Int(color.blueComponent*255));usePen()}
    @objc func changeStyle(_ sender:NSPopUpButton){canvas.currentStyle=["pen","marker","highlighter"][sender.indexOfSelectedItem];usePen()}
    @objc func changeWidth(_ sender:NSSlider){canvas.currentWidth=CGFloat(sender.doubleValue);status.stringValue="굵기 \(Int(sender.doubleValue))"}
    @objc func zoomIn(){canvas.zoom=min(4,canvas.zoom*1.25);status.stringValue="확대 \(Int(canvas.zoom*100))%"}
    @objc func zoomOut(){canvas.zoom=max(0.5,canvas.zoom/1.25);status.stringValue="확대 \(Int(canvas.zoom*100))%"}
    @objc func zoomReset(){canvas.zoom=1;status.stringValue="확대 100%"}
    @objc func clearInk(){let alert=NSAlert();alert.messageText="모든 필기를 지울까요?";alert.addButton(withTitle:"지우기");alert.addButton(withTitle:"취소");if alert.runModal() == .alertFirstButtonReturn{send(["type":"clear"])}}
    @objc func importImage(){let panel=NSOpenPanel();panel.allowedContentTypes=[.png,.jpeg,.heic];guard panel.runModal() == .OK,let url=panel.url,let image=NSImage(contentsOf:url)else{return};let maxSize=NSSize(width:1600,height:1000),scale=min(1,min(maxSize.width/image.size.width,maxSize.height/image.size.height)),size=NSSize(width:image.size.width*scale,height:image.size.height*scale);let target=NSImage(size:size);target.lockFocus();image.draw(in:NSRect(origin:.zero,size:size));target.unlockFocus();guard let tiff=target.tiffRepresentation,let rep=NSBitmapImageRep(data:tiff),let data=rep.representation(using:.jpeg,properties:[.compressionFactor:0.85])else{return};canvas.backgroundImage=target;send(["type":"background","image":"data:image/jpeg;base64,"+data.base64EncodedString()]);status.stringValue="배경 이미지 추가됨"}
    func setBackground(_ value:String){guard let comma=value.firstIndex(of:","),let data=Data(base64Encoded:String(value[value.index(after:comma)...])),let image=NSImage(data:data)else{return};canvas.backgroundImage=image}
    @objc func toggleOverlay(){if canvas.overlayMode{canvas.overlayMode=false;window.level = .normal;window.isOpaque=true;window.backgroundColor = .windowBackgroundColor;window.setFrame(normalFrame,display:true);status.stringValue="화이트보드 모드"}else{normalFrame=window.frame;canvas.overlayMode=true;canvas.backgroundImage=nil;window.isOpaque=false;window.backgroundColor = .clear;window.level = .floating;if let screen=window.screen{window.setFrame(screen.visibleFrame,display:true)};status.stringValue="화면 위 필기 · 내보내기로 화면과 합성"}}
    @objc func saveImage(){let panel=NSSavePanel();panel.allowedContentTypes=[.png,.jpeg];panel.nameFieldStringValue="drawbridge.png";guard panel.runModal() == .OK,let url=panel.url else{return};if canvas.overlayMode{captureOverlay(to:url)}else{let rep=canvas.bitmapImageRepForCachingDisplay(in:canvas.bounds)!;canvas.cacheDisplay(in:canvas.bounds,to:rep);write(rep,to:url)}}
    func captureOverlay(to url:URL){Task{do{let content=try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:true);guard let display=content.displays.first else{throw NSError(domain:"Drawbridge",code:1,userInfo:[NSLocalizedDescriptionKey:"화면을 찾지 못했습니다"])};let ownApps=content.applications.filter{$0.bundleIdentifier == Bundle.main.bundleIdentifier};let filter=SCContentFilter(display:display,excludingApplications:ownApps,exceptingWindows:[]);let config=SCStreamConfiguration();config.width=Int(display.width);config.height=Int(display.height);config.showsCursor=false;let shot=try await SCScreenshotManager.captureImage(contentFilter:filter,configuration:config);await MainActor.run{let ink=self.canvas.bitmapImageRepForCachingDisplay(in:self.canvas.bounds)!;self.canvas.cacheDisplay(in:self.canvas.bounds,to:ink);let composite=NSImage(size:self.canvas.bounds.size);composite.lockFocus();NSImage(cgImage:shot,size:self.canvas.bounds.size).draw(in:self.canvas.bounds);let layer=NSImage(size:self.canvas.bounds.size);layer.addRepresentation(ink);layer.draw(in:self.canvas.bounds);composite.unlockFocus();if let data=composite.tiffRepresentation,let rep=NSBitmapImageRep(data:data){self.write(rep,to:url)}}}catch{await MainActor.run{self.status.stringValue="화면 기록 권한이 필요합니다: \(error.localizedDescription)"}}}}
    func write(_ rep:NSBitmapImageRep,to url:URL){let type:NSBitmapImageRep.FileType=url.pathExtension.lowercased()=="jpg"||url.pathExtension.lowercased()=="jpeg" ? .jpeg:.png;let properties:[NSBitmapImageRep.PropertyKey:Any]=type == .jpeg ? [.compressionFactor:0.9]:[:];do{try rep.representation(using:type,properties:properties)?.write(to:url);status.stringValue="이미지 저장 완료"}catch{status.stringValue=error.localizedDescription}}
    @objc func toggleScreenShare(){if screenTimer != nil{screenTimer?.invalidate();screenTimer=nil;hideAnnotationOverlay();shareButton.title="Mac 화면 공유";send(["type":"share-stop"]);status.stringValue="화면 공유 중지";return};guard socket != nil else{status.stringValue="먼저 보드에 연결하세요";return};showAnnotationOverlay();shareButton.title="공유 중지";status.stringValue="Mac 화면을 태블릿으로 전송 중 · 모바일 필기를 화면에 표시";captureAndSendFrame();screenTimer=Timer.scheduledTimer(withTimeInterval:0.5,repeats:true){[weak self] _ in self?.captureAndSendFrame()}}
    func showAnnotationOverlay(){guard annotationWindow == nil,let screen=window.screen ?? NSScreen.main else{return};let overlay=NSWindow(contentRect:screen.frame,styleMask:[.borderless],backing:.buffered,defer:false,screen:screen);overlay.isOpaque=false;overlay.backgroundColor = .clear;overlay.hasShadow=false;overlay.level = .floating;overlay.ignoresMouseEvents=true;overlay.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary,.stationary];let view=CanvasView(frame:NSRect(origin:.zero,size:screen.frame.size));view.overlayMode=true;view.strokes=canvas.strokes;overlay.contentView=view;overlay.orderFrontRegardless();annotationWindow=overlay;annotationCanvas=view}
    func hideAnnotationOverlay(){annotationWindow?.orderOut(nil);annotationWindow=nil;annotationCanvas=nil}
    func syncAnnotationOverlay(){annotationCanvas?.strokes=canvas.strokes;annotationCanvas?.needsDisplay=true}
    func captureAndSendFrame(){guard !captureBusy else{return};captureBusy=true;Task{defer{Task{@MainActor in self.captureBusy=false}};do{let content=try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:true);guard let display=content.displays.first else{return};let ownApps=content.applications.filter{$0.bundleIdentifier == Bundle.main.bundleIdentifier};let filter=SCContentFilter(display:display,excludingApplications:ownApps,exceptingWindows:[]);let config=SCStreamConfiguration();let scale=min(1.0,1280.0/CGFloat(display.width));config.width=Int(CGFloat(display.width)*scale);config.height=Int(CGFloat(display.height)*scale);config.showsCursor=true;let shot=try await SCScreenshotManager.captureImage(contentFilter:filter,configuration:config);let rep=NSBitmapImageRep(cgImage:shot);if let data=rep.representation(using:.jpeg,properties:[.compressionFactor:0.62]){self.send(["type":"frame","image":"data:image/jpeg;base64,"+data.base64EncodedString()])}}catch{await MainActor.run{self.status.stringValue="화면 기록 권한이 필요합니다: \(error.localizedDescription)";self.screenTimer?.invalidate();self.screenTimer=nil;self.hideAnnotationOverlay();self.shareButton.title="Mac 화면 공유"}}}}
    @objc func savePDF(){let panel=NSSavePanel();panel.allowedContentTypes=[.pdf];panel.nameFieldStringValue="drawbridge.pdf";guard panel.runModal() == .OK,let url=panel.url else{return};do{try canvas.dataWithPDF(inside:canvas.bounds).write(to:url);status.stringValue="PDF 저장 완료"}catch{status.stringValue=error.localizedDescription}}
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool{true}
    func applicationWillTerminate(_ notification:Notification){screenTimer?.invalidate();hideAnnotationOverlay();send(["type":"share-stop"]);tunnelProcess?.terminate();relayProcess?.terminate()}
}

let app=NSApplication.shared
let delegate=AppController()
app.delegate=delegate
app.setActivationPolicy(.regular)
app.run()
