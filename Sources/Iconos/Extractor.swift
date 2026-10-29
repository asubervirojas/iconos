import CoreGraphics
import Foundation

// Extractor del logo, escrito por Codex (OpenAI) en el prototipo y portado aqui sin cambiar la logica:
// detecta la ficha original del icono, la quita y deja solo el logo con el tratamiento de color de cada
// variante. Todo se decide por la imagen, sin nombres de apps.
enum Extractor {

 // Prototype: image-only decisions. No application names, stored masks, or replacement artwork.
 typealias V = SIMD3<Float>
 @inline(__always) static func clamp(_ x: Float, _ a: Float = 0, _ b: Float = 1) -> Float { min(b,max(a,x)) }
 @inline(__always) static func dot(_ a: V,_ b: V) -> Float { a.x*b.x+a.y*b.y+a.z*b.z }
 @inline(__always) static func chromaRGB(_ p: V) -> Float { max(p.x,p.y,p.z)-min(p.x,p.y,p.z) }
 @inline(__always) static func gray(_ p: V) -> Float { (p.x+p.y+p.z)/3 }
 @inline(__always) static func lin(_ v: Float) -> Float { v <= 0.04045 ? v/12.92 : powf((v+0.055)/1.055,2.4) }
 @inline(__always) static func gam(_ v: Float) -> Float { v <= 0.0031308 ? v*12.92 : 1.055*powf(max(0,v),1/2.4)-0.055 }
 static func lab(_ p: V) -> V {
  let r=lin(p.x),g=lin(p.y),b=lin(p.z)
  let l=cbrtf(0.4122214708*r+0.5363325363*g+0.0514459929*b)
  let m=cbrtf(0.2119034982*r+0.6806995451*g+0.1073969566*b)
  let s=cbrtf(0.0883024619*r+0.2817188376*g+0.6299787005*b)
  return V(0.2104542553*l+0.793617785*m-0.0040720468*s,1.9779984951*l-2.428592205*m+0.4505937099*s,0.0259040371*l+0.7827717662*m-0.808675766*s)
 }
 static func rgb(_ p: V) -> V {
  let l=p.x+0.3963377774*p.y+0.2158037573*p.z,m=p.x-0.1055613458*p.y-0.0638541728*p.z,s=p.x-0.0894841775*p.y-1.291485548*p.z
  let a=l*l*l,b=m*m*m,c=s*s*s
  return V(gam(4.0767416621*a-3.3077115913*b+0.2309699292*c),gam(-1.2684380046*a+2.6097574011*b-0.3413193965*c),gam(-0.0041960863*a-0.7034186147*b+1.707614701*c))
 }
 static func gamut(_ l: V) -> V {
  let initial=rgb(l)
  if min(initial.x,initial.y,initial.z)>=0 && max(initial.x,initial.y,initial.z)<=1 {return initial}
  // Continuous chroma compression avoids horizontal bands in smooth gradients.
  var lo:Float=0,hi:Float=1
  for _ in 0..<12 {
   let t=(lo+hi)/2,p=rgb(V(l.x,l.y*t,l.z*t))
   if min(p.x,p.y,p.z)>=0 && max(p.x,p.y,p.z)<=1 {lo=t} else {hi=t}
  }
  let p=rgb(V(l.x,l.y*lo,l.z*lo))
  return V(clamp(p.x),clamp(p.y),clamp(p.z))
 }
 static func darkNeutral(_ p: V) -> V {
  var v=lab(p);let c=hypotf(v.y,v.z)
  if c >= 0.09 || v.x >= 0.78 {return p}
  let amount=clamp((0.09-c)/0.035)*clamp((0.78-v.x)/0.10)
  v.x = v.x*(1-amount)+(0.95-0.38*v.x)*amount
  v.y *= 1-amount*0.7;v.z *= 1-amount*0.7
  return gamut(v)
 }
 static func brandColor(_ p: V, dark: Bool) -> V {
  // A 3:1 minimum against the darkest light tile / lightest dark tile.
  var v=lab(p)
  let target: Float = dark ? 0.18 : 0.247
  func lum(_ p: V) -> Float {0.2126*lin(p.x)+0.7152*lin(p.y)+0.0722*lin(p.z)}
  let y=lum(p)
  if dark ? y >= target : y <= target {return p}
  var lo: Float = dark ? v.x : 0, hi: Float = dark ? 1 : v.x
  for _ in 0..<9 {
   v.x=(lo+hi)/2
   if lum(gamut(v)) < target {lo=v.x} else {hi=v.x}
  }
  v.x=(lo+hi)/2;return gamut(v)
 }
 struct Box {var x0:Int;var y0:Int;var x1:Int;var y1:Int;var w:Int{x1-x0+1};var h:Int{y1-y0+1}}
 struct Raster {
  let w:Int,h:Int;var bytes:[UInt8]
  init(_ im:CGImage) {
   w=im.width;h=im.height;bytes=[UInt8](repeating:0,count:w*h*4)
   bytes.withUnsafeMutableBytes { ptr in
    let c=CGContext(data:ptr.baseAddress,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:Lienzo.espacio,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.draw(im,in:CGRect(x:0,y:0,width:w,height:h))
   }
  }
  @inline(__always) func color(_ i:Int)->V {let j=i*4;let a=Float(max(1,bytes[j+3]));return V(Float(bytes[j])/a,Float(bytes[j+1])/a,Float(bytes[j+2])/a)}
  func image()->CGImage {
   let data=Data(bytes) as CFData
   return CGImage(width:w,height:h,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:w*4,space:Lienzo.espacio,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:CGDataProvider(data:data)!,decode:nil,shouldInterpolate:true,intent:.defaultIntent)!
  }
 }
 struct Model {
  var k:[V]
  @inline(__always) func at(_ x:Float,_ y:Float)->V {
   let v=k[0]+k[1]*x+k[2]*y+k[3]*(x*x)+k[4]*(x*y)+k[5]*(y*y)
   return V(clamp(v.x),clamp(v.y),clamp(v.z))
  }
 }
 static func fit(_ samples:[(Float,Float,V)]) -> Model {
  var model=Model(k:[V](repeating:.zero,count:6))
  for iter in 0..<3 {
   var a=[[Double]](repeating:[Double](repeating:0,count:9),count:6)
   for (x,y,p) in samples {
    if iter>0 {let d=p-model.at(x,y);if dot(d,d)>0.012 {continue}}
    let t=[1.0,Double(x),Double(y),Double(x*x),Double(x*y),Double(y*y)]
    for i in 0..<6 {for j in 0..<6 {a[i][j]+=t[i]*t[j]};a[i][6]+=t[i]*Double(p.x);a[i][7]+=t[i]*Double(p.y);a[i][8]+=t[i]*Double(p.z)}
   }
   for i in 0..<6 {
    a[i][i]+=1e-7
    var best=i;for j in i..<6 {if abs(a[j][i])>abs(a[best][i]) {best=j}}
    if best != i {a.swapAt(i,best)}
    let f=a[i][i];for j in i..<9 {a[i][j]/=f}
    for r in 0..<6 where r != i {let m=a[r][i];for j in i..<9 {a[r][j]-=m*a[i][j]}}
   }
   model.k=(0..<6).map{V(Float(a[$0][6]),Float(a[$0][7]),Float(a[$0][8]))}
  }
  return model
 }
 struct Extraction {
  let logo: CGImage
  let light: CGImage
  let dark: CGImage
  let destino: CGRect
  let plate: Bool
  let color: V
  let mode: String
  let details: String
  /// Se asigna en cada return de la extraccion (Mantenimiento.swift)
  var confianza: Confianza = .alta
  var motivos: [String] = []
 }

 // Compares the opaque silhouette, not its bounding-box occupancy. Shadow and
 // antialias pixels below the threshold do not count as foreground.
 static func silhouette(_ src: Raster, _ box: Box, threshold: UInt8 = 240) -> (circle: Bool, error: Float) {
  let aspect = Float(box.w) / Float(box.h)
  guard box.w > 2, box.h > 2, aspect > 0.75, aspect < 1.33 else { return (false, 1) }
  var errors = [Int](repeating: 0, count: 12), count = 0
  for y in stride(from: box.y0, through: box.y1, by: 5) {
   for x in stride(from: box.x0, through: box.x1, by: 5) {
    let u = abs(2 * Float(x-box.x0) / Float(box.w-1) - 1)
    let v = abs(2 * Float(y-box.y0) / Float(box.h-1) - 1)
    let occupied = src.bytes[(y*src.w+x)*4+3] > threshold
    // Circle, superellipses and ordinary rounded rectangles, in the same box.
    for (j, power) in [Float(2), 2.5, 3, 4, 5, 6].enumerated() {
     if (powf(u, power) + powf(v, power) <= 1) != occupied { errors[j] += 1 }
    }
    for (j, radius) in [Float(0.25), 0.35, 0.45, 0.55, 0.70, 0.85].enumerated() {
     let dx = max(0, u-(1-radius)), dy = max(0, v-(1-radius))
     if (dx*dx + dy*dy <= radius*radius) != occupied { errors[j+6] += 1 }
    }
    count += 1
   }
  }
  return (aspect > 0.94 && aspect < 1.06 && Float(errors[0])/Float(count) < 0.025,
          Float(errors.min()!)/Float(count))
 }

 // All variants share one alpha mask. Remove isolated dust without changing
 // antialiasing on meaningful components. Eight-neighbour connectivity preserves diagonals.
 static func cleanAlpha(_ raw: inout Raster, _ light: inout Raster, _ dark: inout Raster,
                 _ box: Box, circle: Bool = false) -> (removed: Int, bounds: Box?) {
  let w = raw.w, h = raw.h, total = w*h
  var seen = [UInt8](repeating: 0, count: total), queue = [Int]()
  queue.reserveCapacity(total/2)
  var removed = 0, bounds: Box? = nil
  for start in 0..<total where raw.bytes[start*4+3] > 0 && seen[start] == 0 {
   queue.removeAll(keepingCapacity: true); queue.append(start); seen[start] = 1
   var head = 0, b = Box(x0: w, y0: h, x1: 0, y1: 0), mass: Float = 0
   while head < queue.count {
    let i = queue[head], x = i%w, y = i/w; head += 1
    b.x0 = min(b.x0,x); b.x1 = max(b.x1,x); b.y0 = min(b.y0,y); b.y1 = max(b.y1,y)
    mass += Float(raw.bytes[i*4+3])/255
    for yy in max(0,y-1)...min(h-1,y+1) { for xx in max(0,x-1)...min(w-1,x+1) {
     let j = yy*w+xx
     if seen[j] == 0 && raw.bytes[j*4+3] > 0 { seen[j] = 1; queue.append(j) }
    }}
   }
   let cx = Float(b.x0+b.x1-box.x0*2)/Float(box.w)-1
   let cy = Float(b.y0+b.y1-box.y0*2)/Float(box.h)-1
   let rim = max(abs(cx),abs(cy)) > 0.88 || cx*cx+cy*cy > (circle ? 0.81 : 1.10)
   if mass < max(24,Float(total)*0.00012) || (rim && mass < Float(box.w*box.h)*0.008) {
    removed += 1
    for i in queue { for k in 0..<4 { raw.bytes[i*4+k] = 0; light.bytes[i*4+k] = 0; dark.bytes[i*4+k] = 0 } }
   } else if var previous = bounds {
    previous.x0 = min(previous.x0,b.x0); previous.x1 = max(previous.x1,b.x1)
    previous.y0 = min(previous.y0,b.y0); previous.y1 = max(previous.y1,b.y1); bounds = previous
   } else { bounds = b }
  }
  return (removed,bounds)
 }
 // Low-contrast construction drawings: remove both the outer white support
 // and the dominant pale field, keeping only the lines. No icon fingerprint.
 static func flatTemplate(_ src:Raster,_ box:Box)->Extraction? {
  let w=src.w,h=src.h,n=w*h
  var histogram=[Int](repeating:0,count:32768),count=0
  for y in box.y0...box.y1 {for x in box.x0...box.x1 where src.bytes[(y*w+x)*4+3]>240 {
   let p=src.color(y*w+x)
   let key=(Int(clamp(p.x)*255)/8)*1024+(Int(clamp(p.y)*255)/8)*32+Int(clamp(p.z)*255)/8
   histogram[key]+=1;count+=1
  }}
  guard let key=histogram.indices.max(by:{histogram[$0]<histogram[$1]}),histogram[key]>count*3/5 else {return nil}
  var base=V.zero
  for y in box.y0...box.y1 {for x in box.x0...box.x1 where src.bytes[(y*w+x)*4+3]>240 {
   let p=src.color(y*w+x)
   let bin=(Int(clamp(p.x)*255)/8)*1024+(Int(clamp(p.y)*255)/8)*32+Int(clamp(p.z)*255)/8
   if bin==key {base+=p}
  }}
  base/=Float(histogram[key])
  guard gray(base)>0.70 && gray(base)<0.94 && chromaRGB(base)<0.12 else {return nil}
  var left=[Int](repeating:w,count:h),right=[Int](repeating:-1,count:h)
  var top=[Int](repeating:h,count:w),bottom=[Int](repeating:-1,count:w)
  var unusual=0
  for y in box.y0...box.y1 {for x in box.x0...box.x1 {
   let p=src.color(y*w+x),d=p-base
   if dot(d,d)<0.001 {
    left[y]=min(left[y],x);right[y]=max(right[y],x);top[x]=min(top[x],y);bottom[x]=max(bottom[x],y)
   }
   if src.bytes[(y*w+x)*4+3]>240 && (gray(p)<0.65 || chromaRGB(p)>0.16) {unusual+=1}
  }}
  guard unusual<count/50 else {return nil}
  // Full-width grid lines interrupt the field samples. Bridge those narrow
  // gaps in the support domain so horizontal/vertical strokes are not erased.
  let oldLeft=left,oldRight=right,oldTop=top,oldBottom=bottom
  for y in box.y0...box.y1 where right[y]<left[y] {
   for d in 1...12 {
    let a=max(box.y0,y-d),b=min(box.y1,y+d)
    if oldRight[a]>=oldLeft[a] && oldRight[b]>=oldLeft[b] {
     left[y]=(oldLeft[a]+oldLeft[b])/2;right[y]=(oldRight[a]+oldRight[b])/2;break
    }
   }
  }
  for x in box.x0...box.x1 where bottom[x]<top[x] {
   for d in 1...12 {
    let a=max(box.x0,x-d),b=min(box.x1,x+d)
    if oldBottom[a]>=oldTop[a] && oldBottom[b]>=oldTop[b] {
     top[x]=(oldTop[a]+oldTop[b])/2;bottom[x]=(oldBottom[a]+oldBottom[b])/2;break
    }
   }
  }
  var raw=src,light=src,dark=src
  raw.bytes=[UInt8](repeating:0,count:n*4);light.bytes=raw.bytes;dark.bytes=raw.bytes
  var mass:Float=0
  for y in box.y0...box.y1 {for x in box.x0...box.x1 {
   guard x>left[y]+3 && x<right[y]-3 && y>top[x]+3 && y<bottom[x]-3 else {continue}
   let p=src.color(y*w+x)
   let a=clamp((gray(p)-gray(base)-0.006)/0.075)
   mass+=a
   let i=(y*w+x)*4
   for c in 0..<3 {raw.bytes[i+c]=UInt8(a*255);light.bytes[i+c]=UInt8(a*90);dark.bytes[i+c]=UInt8(a*220)}
   raw.bytes[i+3]=UInt8(a*255);light.bytes[i+3]=raw.bytes[i+3];dark.bytes[i+3]=raw.bytes[i+3]
  }}
  guard mass>Float(count)*0.002 && mass<Float(count)*0.08 else {return nil}
  // A thin circular guideline may merge with the white support at its four
  // tangencies. Complete it only if the measured remaining arc supports a
  // circle around the field centre; radius and position come from the image.
  let validX=left.indices.filter {right[$0]>=left[$0]}
  let validY=top.indices.filter {bottom[$0]>=top[$0]}
  if let x0=validX.map({left[$0]}).min(),let x1=validX.map({right[$0]}).max(),
     let y0=validY.map({top[$0]}).min(),let y1=validY.map({bottom[$0]}).max(),abs((x1-x0)-(y1-y0))<5 {
   let cx=Float(x0+x1)/2,cy=Float(y0+y1)/2,estimate=Float(x1-x0+1)/2
   var bestRadius=estimate,bestScore:Float=0
   for step in -16...16 {
    let radius=estimate+Float(step)*0.25
    var score:Float=0
    for k in 0..<360 {
     let t=Float(k)*Float.pi/180,x=Int((cx+cosf(t)*radius).rounded()),y=Int((cy+sinf(t)*radius).rounded())
     if x>0 && x<w-1 && y>0 && y<h-1 {score+=Float(raw.bytes[(y*w+x)*4+3])/255}
    }
    if score>bestScore {bestScore=score;bestRadius=radius}
   }
   if bestScore>360*0.60 {
    for y in max(0,y0-3)...min(h-1,y1+3) {for x in max(0,x0-3)...min(w-1,x1+3) {
     let a=0.9*clamp(1.2-abs(hypotf(Float(x)-cx,Float(y)-cy)-bestRadius)),i=(y*w+x)*4
     if a>Float(raw.bytes[i+3])/255 {
      for c in 0..<3 {raw.bytes[i+c]=UInt8(a*255);light.bytes[i+c]=UInt8(a*90);dark.bytes[i+c]=UInt8(a*220)}
      raw.bytes[i+3]=UInt8(a*255);light.bytes[i+3]=raw.bytes[i+3];dark.bytes[i+3]=raw.bytes[i+3]
     }
    }}
   }
  }
  let crop=CGRect(x:box.x0,y:box.y0,width:box.w,height:box.h)
  return Extraction(logo:raw.image(),light:light.image().cropping(to:crop)!,dark:dark.image().cropping(to:crop)!,destino:Lienzo.cuerpo,plate:true,color:base,mode:"dibujo de plantilla sin ficha",details:"campo palido uniforme retirado; lineas originales con contraste",confianza:.media,motivos:["dibujo de plantilla sin ficha"])
 }

 // When a silver support defeats the smooth-matte fit, a closed dark frame
 // around a chromatic interior is still separable. Preserve that complete
 // enclosure (including white controls), discard its surrounding support.
 static func framedArtwork(_ src:Raster,_ box:Box)->Extraction? {
  let w=src.w,h=src.h,n=w*h
  var mask=[UInt8](repeating:0,count:n),visited=mask,queue=[Int](),best=[Int]()
  for y in box.y0...box.y1 {for x in box.x0...box.x1 {
   let i=y*w+x,p=src.color(i)
   if src.bytes[i*4+3]>250 && (gray(p)<0.40 || chromaRGB(p)>0.20) {mask[i]=1}
  }}
  for start in 0..<n where mask[start]>0 && visited[start]==0 {
   queue=[start];visited[start]=1;var head=0
   while head<queue.count {
    let i=queue[head],x=i%w,y=i/w;head+=1
    for (xx,yy) in [(x-1,y),(x+1,y),(x,y-1),(x,y+1)] where xx>=0 && xx<w && yy>=0 && yy<h {
     let j=yy*w+xx
     if mask[j]>0 && visited[j]==0 {visited[j]=1;queue.append(j)}
    }
   }
   if queue.count>best.count {best=queue}
  }
  guard best.count>box.w*box.h/3 else {return nil}
  mask=[UInt8](repeating:0,count:n)
  var b=Box(x0:w,y0:h,x1:0,y1:0),colored=0,dark=0
  for i in best {
   mask[i]=1;b.x0=min(b.x0,i%w);b.x1=max(b.x1,i%w);b.y0=min(b.y0,i/w);b.y1=max(b.y1,i/w)
   let p=src.color(i)
   if chromaRGB(p)>0.20 {colored+=1}
   if gray(p)<0.30 && chromaRGB(p)<0.08 {dark+=1}
  }
  guard b.w>box.w*2/3 && b.h>box.h/2 && b.w<box.w*98/100 && b.h<box.h*95/100 && colored>best.count/2 && dark>best.count/20 else {return nil}
  // The boundary itself must be dark, not an arbitrary colourful silhouette.
  var boundary=0,neutral=0
  for i in best where i%w>0 && i%w<w-1 && i/w>0 && i/w<h-1 {
   if mask[i-1]==0 || mask[i+1]==0 || mask[i-w]==0 || mask[i+w]==0 {
    boundary+=1;let p=src.color(i)
    if gray(p)<0.4 && chromaRGB(p)<0.10 {neutral+=1}
   }
  }
  // White controls add inner boundaries, so allow them in this conservative vote.
  guard neutral>boundary/2 else {return nil}
  var outside=[UInt8](repeating:0,count:n)
  queue=[0];outside[0]=1;var head=0
  while head<queue.count {
   let i=queue[head],x=i%w,y=i/w;head+=1
   for (xx,yy) in [(x-1,y),(x+1,y),(x,y-1),(x,y+1)] where xx>=0 && xx<w && yy>=0 && yy<h {
    let j=yy*w+xx
    if mask[j]==0 && outside[j]==0 {outside[j]=1;queue.append(j)}
   }
  }
  var out=src;out.bytes=[UInt8](repeating:0,count:n*4)
  for y in max(0,b.y0-3)...min(h-1,b.y1+3) {for x in max(0,b.x0-3)...min(w-1,b.x1+3) {
   let i=y*w+x,p=src.color(i)
   var a:Float=outside[i]==0 ? 1:0,ink=p
   var nearest = -1,score=100
   for dy in -3...3 {for dx in -3...3 {
    let xx=x+dx,yy=y+dy
    if xx>=0 && xx<w && yy>=0 && yy<h && outside[yy*w+xx] != outside[i] && dx*dx+dy*dy<score {nearest=yy*w+xx;score=dx*dx+dy*dy}
   }}
   if nearest>=0 {
    let dx=x-nearest%w,dy=y-nearest/w
    let length=max(1,sqrtf(Float(dx*dx+dy*dy)))
    let sign:Float=outside[i]>0 ? 1:-1
    let bx=min(w-1,max(0,x+Int(Float(dx)/length*6*sign))),by=min(h-1,max(0,y+Int(Float(dy)/length*6*sign)))
    let fx=min(w-1,max(0,x-Int(Float(dx)/length*6*sign))),fy=min(h-1,max(0,y-Int(Float(dy)/length*6*sign)))
    let bg=src.color(by*w+bx),f=src.color(fy*w+fx),d=f-bg
    if gray(bg)>0.5 && gray(f)<0.3 && chromaRGB(f)<0.10 {
     a=clamp(dot(p-bg,d)/max(0.001,dot(d,d)));ink=f
    }
   }
   for c in 0..<3 {out.bytes[i*4+c]=UInt8(clamp(ink[c])*a*255+0.5)}
   out.bytes[i*4+3]=UInt8(a*255+0.5)
  }}
  var lightCopy=out,darkCopy=out
  _=cleanAlpha(&out,&lightCopy,&darkCopy,box)
  let cropBox=CGRect(x:max(0,b.x0-3),y:max(0,b.y0-3),width:min(w-b.x0,b.w+6),height:min(h-b.y0,b.h+6))
  let crop=out.image().cropping(to:cropBox)!
  let scale=CGFloat(0.64*1024)/max(cropBox.width,cropBox.height)
  let dest=CGRect(x:512-cropBox.width*scale/2,y:512-cropBox.height*scale/2,width:cropBox.width*scale,height:cropBox.height*scale)
  return Extraction(logo:out.image(),light:crop,dark:crop,destino:dest,plate:true,color:.zero,mode:"dibujo con marco cerrado",details:"soporte metalico retirado; marco oscuro e interior conservados",confianza:.media,motivos:["dibujo con marco cerrado"])
 }
 static func extract(_ image:CGImage)->Extraction {
  let src=Raster(image),w=src.w,h=src.h,total=w*h
  var box=Box(x0:w,y0:h,x1:0,y1:0),opaque=0
  for y in 0..<h {for x in 0..<w where src.bytes[(y*w+x)*4+3]>240 {box.x0=min(x,box.x0);box.x1=max(x,box.x1);box.y0=min(y,box.y0);box.y1=max(y,box.y1);opaque+=1}}
  // Transparent/degenerate inputs use the same safe fallback as freeform art.
  if opaque == 0 { box = Box(x0:0,y0:0,x1:w-1,y1:h-1) }
  let fill=Float(opaque)/Float(box.w*box.h)
  var shape=silhouette(src,box), alphaCutoff:UInt8=240
  // Some bundle tiles have a translucent lower half (alpha 230-240).
  // A larger translucent tile can surround a perfectly circular opaque logo.
  do {
   for threshold: UInt8 in [208,160] {
    var candidate=Box(x0:w,y0:h,x1:0,y1:0)
    for y in 0..<h {for x in 0..<w where src.bytes[(y*w+x)*4+3]>threshold {
     candidate.x0=min(candidate.x0,x);candidate.x1=max(candidate.x1,x)
     candidate.y0=min(candidate.y0,y);candidate.y1=max(candidate.y1,y)
    }}
    if candidate.w>2 && candidate.h>2 {
     let match=silhouette(src,candidate,threshold:threshold)
     if (shape.error>=0.035 && match.error<shape.error) ||
        (match.error<0.035 && Float(candidate.w*candidate.h)>Float(box.w*box.h)*1.15) {
      box=candidate;shape=match;alphaCutoff=threshold
     }
    }
   }
  }
  let isCircle=shape.circle
  let isPlate=opaque>0 && shape.error<0.035
  var reason = isPlate ? "fondo no separable con confianza" : "silueta libre"
  func unchanged(_ motivo: String? = nil) -> Extraction {
   // Existing freeform path: crop all visible alpha, then use the original maximum side of 0.64.
   var b=Box(x0:w,y0:h,x1:0,y1:0)
   for y in 0..<h {for x in 0..<w where src.bytes[(y*w+x)*4+3]>12 {b.x0=min(x,b.x0);b.x1=max(x,b.x1);b.y0=min(y,b.y0);b.y1=max(y,b.y1)}}
   if b.x0 > b.x1 || b.y0 > b.y1 { b=Box(x0:0,y0:0,x1:w-1,y1:h-1) }
   let crop=image.cropping(to:CGRect(x:b.x0,y:b.y0,width:b.w,height:b.h))!
   let factor=0.64*1024/CGFloat(max(b.w,b.h))
   let destino=CGRect(x:512-CGFloat(b.w)*factor/2,y:512-CGFloat(b.h)*factor/2,width:CGFloat(b.w)*factor,height:CGFloat(b.h)*factor)
   let fiable = opaque>0 && !isPlate && motivo==nil
   let aviso = motivo ?? (opaque==0 ? "el icono no tiene contenido opaco" : (isPlate ? "fondo no separable con confianza" : "silueta libre sin ficha"))
   return Extraction(logo:image,light:crop,dark:crop,destino:destino,plate:false,color:.zero,mode:"arte completo",details:String(format:"ocupacion=%.3f; error_silueta=%.4f; %@",fill,shape.error,reason),confianza:fiable ? .alta:.baja,motivos:[aviso])
  }
  if !isPlate {return unchanged()}
  // A chromatic ring joined to ink of the same colour is an emblem. Removing
  // its perimeter would amputate the drawing. Keep its white field and trim
  // only the external shadow, using the measured circular silhouette.
  if isCircle {
   var ring=[V](),whiteInside=0,sameInside=0
   for k in 0..<180 {
    let t=Float(k)*2*Float.pi/180
    func point(_ r:Float)->V {
     let x=Int(Float(box.x0+box.x1)/2+cosf(t)*Float(box.w-1)*r/2)
     let y=Int(Float(box.y0+box.y1)/2+sinf(t)*Float(box.h-1)*r/2)
     return src.color(y*w+x)
    }
    ring.append(point(0.975))
    let inner=point(0.83)
    if gray(inner)>0.90 && chromaRGB(inner)<0.08 {whiteInside+=1}
    if chromaRGB(inner)>0.30 {sameInside+=1}
   }
   let mean=ring.reduce(V.zero,+)/Float(ring.count)
   let uniform=ring.filter {dot($0-mean,$0-mean)<0.025}.count
   if chromaRGB(mean)>0.30 && uniform>170 && whiteInside>65 && sameInside>15 {
    var clean=src
    let cx=Float(box.x0+box.x1)/2,cy=Float(box.y0+box.y1)/2
    let rx=Float(box.w)/2,ry=Float(box.h)/2
    for y in 0..<h {for x in 0..<w {
     let i=(y*w+x)*4,u=(Float(x)-cx)/rx,v=(Float(y)-cy)/ry
     let a=clamp((1-sqrtf(u*u+v*v))*min(rx,ry)+0.5)
     for c in 0..<4 {clean.bytes[i+c]=UInt8(Float(src.bytes[i+c])*a+0.5)}
    }}
    let crop=clean.image().cropping(to:CGRect(x:box.x0,y:box.y0,width:box.w,height:box.h))!
    let size=CGFloat(0.64*1024),ratio=CGFloat(box.h)/CGFloat(box.w)
    return Extraction(logo:clean.image(),light:crop,dark:crop,destino:CGRect(x:512-size/2,y:512-size*ratio/2,width:size,height:size*ratio),plate:false,color:mean,mode:"emblema circular unido",details:"aro cromatico continuo e interior unido; sombra exterior retirada",confianza:.media,motivos:["emblema circular unido; se conserva el aro"])
   }
  }
  // A large uniform dark disc surrounding light strokes is a second matte,
  // not dark ink to invert. Validate the complete annulus before peeling it.
  if !isCircle {
   var disc=Box(x0:w,y0:h,x1:0,y1:0),darkCount=0
   for y in box.y0...box.y1 {for x in box.x0...box.x1 {
    let p=src.color(y*w+x)
    if src.bytes[(y*w+x)*4+3]>240 && gray(p)<0.16 && chromaRGB(p)<0.06 {
     disc.x0=min(disc.x0,x);disc.x1=max(disc.x1,x);disc.y0=min(disc.y0,y);disc.y1=max(disc.y1,y);darkCount+=1
    }
   }}
   if disc.w>box.w*2/3 && disc.w<box.w*9/10 && abs(disc.w-disc.h)<max(3,disc.w/50) && darkCount>disc.w*disc.h/2 {
    var ringOK=0
    for k in 0..<240 {
     let t=Float(k)*2*Float.pi/240
     let x=Int(Float(disc.x0+disc.x1)/2+cosf(t)*Float(disc.w)*0.46)
     let y=Int(Float(disc.y0+disc.y1)/2+sinf(t)*Float(disc.h)*0.46)
     let p=src.color(y*w+x)
     if gray(p)<0.16 && chromaRGB(p)<0.06 {ringOK+=1}
    }
    if ringOK>236 {
     var inner=src
     for y in 0..<h {for x in 0..<w {
      let u=Float(2*x-disc.x0-disc.x1)/Float(disc.w),v=Float(2*y-disc.y0-disc.y1)/Float(disc.h)
      if u*u+v*v>0.99 {for c in 0..<4 {inner.bytes[(y*w+x)*4+c]=0}}
     }}
     let result=extract(inner.image())
     if result.plate {return Extraction(logo:result.logo,light:result.light,dark:result.dark,destino:result.destino,plate:true,color:result.color,mode:result.mode,details:"fondo circular anidado retirado; "+result.details,confianza:min(.media,result.confianza),motivos:["fondo circular anidado"]+(result.confianza == .alta ? []:result.motivos))}
    }
   }
  }
  var samples=[(Float,Float,V)]()
  for y in stride(from:box.y0,through:box.y1,by:max(1,h/160)) {for x in stride(from:box.x0,through:box.x1,by:max(1,w/160)) {
   let u=2*Float(x-box.x0)/Float(box.w-1)-1,v=2*Float(y-box.y0)/Float(box.h-1)-1
   let edge=max(abs(u),abs(v))
   let band=isCircle ? (u*u+v*v>0.67 && u*u+v*v<0.81) : (edge>(alphaCutoff<240 ? 0.88:0.76) && edge<(alphaCutoff<240 ? 0.94:0.90) && min(abs(u),abs(v))<0.65)
   if band && src.bytes[(y*w+x)*4+3]>min(250,Int(alphaCutoff)+10) {samples.append((u,v,src.color(y*w+x)))}
  }}
  var model=fit(samples)
  var center=model.at(0,0)
  // Require an approximately uniform / smooth opaque plate, not just a solid silhouette.
  let inliers=samples.filter { let d=$0.2-model.at($0.0,$0.1);return dot(d,d)<0.0144 }.count
  if samples.count>=64 && Float(inliers)/Float(samples.count)<0.85 {
   // Metallic plates can include a dark bezel in the sampling band. Fit the
   // neutral silver support separately, never the coloured screen or bezel.
   let silver=samples.filter {chromaRGB($0.2)<0.05 && gray($0.2)>0.55}
   if silver.count>samples.count/2 {
    model=fit(silver);center=model.at(0,0)
    samples=silver
   }
  }
  let finalInliers=samples.filter {let d=$0.2-model.at($0.0,$0.1);return dot(d,d)<0.0144}.count
  if samples.count<64 || Float(finalInliers)/Float(samples.count)<0.85 {reason += String(format:"; muestras=%d; ajuste=%.3f",samples.count,Float(finalInliers)/Float(max(1,samples.count)));if let drawing=flatTemplate(src,box) {return drawing}
   if let drawing=framedArtwork(src,box) {return drawing}
   return unchanged()}
  let colored=chromaRGB(center)>0.15 || gray(center)<0.40
  if !colored {
   let neutral=samples.filter { chromaRGB($0.2)<0.035 && gray($0.2)>0.75 }.map { ($0.0,$0.1,V(repeating:gray($0.2))) }
   if neutral.count>samples.count/2 {model=fit(neutral);center=model.at(0,0)}
  }
  var colors=[V](repeating:.zero,count:total),bg=[V](repeating:.zero,count:total)
  var eligible=[UInt8](repeating:0,count:total)
  var strong=[UInt8](repeating:0,count:total),white=[UInt8](repeating:0,count:total)
  var lightForeground=0,otherForeground=0
  for y in box.y0...box.y1 {for x in box.x0...box.x1 {
   let i=y*w+x,p=src.color(i),u=2*Float(x-box.x0)/Float(box.w-1)-1,v=2*Float(y-box.y0)/Float(box.h-1)-1,b=model.at(u,v)
   colors[i]=p;bg[i]=b
   guard src.bytes[i*4+3]>240 else {continue}
   // Reject the original plate rim and shadow before any color segmentation.
   let edge=max(abs(u),abs(v));if isCircle ? u*u+v*v>0.92 : edge>0.94 {continue}
   eligible[i]=1
   if colored {
    let d=p-b
    if dot(d,d)>0.10 {
     if gray(p)>0.65 && chromaRGB(p)<0.30 {lightForeground+=1;strong[i]=1} else {otherForeground+=1}
    }
   } else {
    let delta=max(b.x-p.x,b.y-p.y,b.z-p.z)
    if delta>0.32 || chromaRGB(p)>0.16 {strong[i]=1}
    if chromaRGB(p)<0.16 && gray(p)>gray(b)-0.40 {white[i]=1}
   }
  }}
  let brand=colored && lightForeground>otherForeground*2
  let separation:Float = chromaRGB(center)<0.1 && gray(center)<0.15 ? 0.035 : 0.10
  if colored && !brand {
   for i in 0..<total where eligible[i]>0 {let d=colors[i]-bg[i];if dot(d,d)>separation {strong[i]=1}}
  }
  // Preserve white ink inside colored emblems, but punch out neutral negative space.
  // Components attached to the plate background are always removed.
  var retainedWhite=0,triangularHoles=0
  var protected=[UInt8](repeating:0,count:total)
  if !colored {
   var visited=[UInt8](repeating:0,count:total),queue=[Int]();queue.reserveCapacity(total)
   for start in 0..<total where white[start]>0 && visited[start]==0 {
    queue.removeAll(keepingCapacity:true);queue.append(start);visited[start]=1
    var head=0,touches=false,boundary=0,colorBoundary=0
    var region=Box(x0:w,y0:h,x1:0,y1:0)
    while head<queue.count {
     let i=queue[head];head+=1;let x=i%w,y=i/w
     region.x0=min(region.x0,x);region.x1=max(region.x1,x);region.y0=min(region.y0,y);region.y1=max(region.y1,y)
     if x<=box.x0+3 || x>=box.x1-3 || y<=box.y0+3 || y>=box.y1-3 {touches=true}
     if isCircle {
      let u=2*Float(x-box.x0)/Float(box.w-1)-1,v=2*Float(y-box.y0)/Float(box.h-1)-1
      if u*u+v*v>0.85 {touches=true}
     }
     for j in [i-1,i+1,i-w,i+w] where j>=0 && j<total {
      if white[j]>0 {if visited[j]==0 {visited[j]=1;queue.append(j)}}
      else if src.bytes[j*4+3]>240 {boundary+=1;if chromaRGB(colors[j])>0.13 {colorBoundary+=1}}
     }
    }
    // A large, solid, convex three-sided void is negative space, not a letter.
    // Its row spans describe a triangle independently of orientation or app identity.
    var triangular=false
    if !touches && queue.count>box.w*box.h/100 {
     var left=[Int](repeating:w,count:region.h),right=[Int](repeating:-1,count:region.h)
     for i in queue {let row=i/w-region.y0;left[row]=min(left[row],i%w);right[row]=max(right[row],i%w)}
     let areaRatio=Float(queue.count)/Float(region.w*region.h)
     var solid=0
     for row in 0..<region.h {if right[row]>=left[row] {solid+=right[row]-left[row]+1}}
     if areaRatio>0.35 && areaRatio<0.62 && Float(queue.count)>Float(solid)*0.97 {
      var points=[SIMD2<Float>]()
      for row in 0..<region.h where right[row]>=left[row] {
       points.append(SIMD2(Float(left[row]),Float(row)))
       points.append(SIMD2(Float(right[row]),Float(row)))
      }
      points.sort {$0.x == $1.x ? $0.y<$1.y : $0.x<$1.x}
      func cross(_ a:SIMD2<Float>,_ b:SIMD2<Float>,_ c:SIMD2<Float>)->Float {
       (b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x)
      }
      var hull=[SIMD2<Float>]()
      for p in points {
       while hull.count>=2 && cross(hull[hull.count-2],hull.last!,p)<=0 {hull.removeLast()}
       hull.append(p)
      }
      let lower=hull.count
      for p in points.dropLast().reversed() {
       while hull.count>lower && cross(hull[hull.count-2],hull.last!,p)<=0 {hull.removeLast()}
       hull.append(p)
      }
      if !hull.isEmpty {hull.removeLast()}
      let tolerance=max(1.5,Float(min(region.w,region.h))*0.015)
      while hull.count>3 {
       var best=0,error=Float.greatestFiniteMagnitude
       for j in hull.indices {
        let a=hull[(j+hull.count-1)%hull.count],b=hull[j],c=hull[(j+1)%hull.count]
        let d=abs(cross(a,c,b))/max(1,hypotf(c.x-a.x,c.y-a.y))
        if d<error {error=d;best=j}
       }
       if error>tolerance {break}
       hull.remove(at:best)
      }
      triangular=hull.count==3
     }
    }
    if triangular {triangularHoles+=1}
    if !touches && !triangular && Float(queue.count)<Float(box.w*box.h)*0.08 && colorBoundary>boundary*2/3 {
     for i in queue {
      strong[i]=1
      // The white ink and its transition into colored ink are opaque, not a matte edge.
      for dy in -2...2 {for dx in -2...2 {
       let j=i+dy*w+dx
       if j>=0 && j<total {protected[j]=1;strong[j]=1}
      }}
     };retainedWhite+=1
    }
   }
  }
  // A chromatic emblem's neutral drop shadow must not turn into a white halo.
  // Only invert neutral ink when it is a substantial part of the design.
  var neutralMass=0,chromaticMass=0,foregroundMass=0,pureMass=0
  if !brand {for i in 0..<total where strong[i]>0 {
   let p=colors[i];foregroundMass+=1
   if min(p.x,p.y,p.z)<0.035 && max(p.x,p.y,p.z)>0.80 {pureMass+=1}
   if chromaRGB(p)<0.16 && gray(p)<0.65 {neutralMass+=1}
   if chromaRGB(p)>0.16 {chromaticMass+=1}
  }}
  let invertNeutral=neutralMass>total/500 && (colored
   ? chromaRGB(center)>0.15 && Float(neutralMass)>Float(foregroundMass)*0.65 && neutralMass>chromaticMass*3
   : Float(neutralMass)>Float(chromaticMass)*0.12)
  // Reliable foreground samples are eroded before a two-pass nearest-seed
  // transform. Narrow / shaded artwork keeps the original 4 or 12 px radius;
  // resampled saturated ink uses deeper samples to exclude baked edge rings.
  // Saturated ink without enclosed pale artwork makes matte recovery well
  // conditioned. Keep the conservative small-radius path for shaded objects,
  // narrow embossed strokes and white lettering; distant samples lose those.
  let refinedMatte = !colored && retainedWhite==0 &&
   (pureMass>foregroundMass/10 || triangularHoles>0)
  let resampledInk = refinedMatte && (pureMass>foregroundMass/2 || invertNeutral)
  let radius = resampledInk ? (invertNeutral ? 20:32) : (!colored && !invertNeutral ? 12:4)
  if box.w<=radius*2 || box.h<=radius*2 {reason="ficha demasiado pequena";return unchanged("ficha demasiado pequeña")}
  let limit=radius*3
  var nearest=[Int32](repeating:-1,count:total),dist=[Int16](repeating:30000,count:total)
  for y in (box.y0+radius)...(box.y1-radius) {for x in (box.x0+radius)...(box.x1-radius) {
   let i=y*w+x
   if strong[i]>0 && strong[i-radius]>0 && strong[i+radius]>0 && strong[i-radius*w]>0 && strong[i+radius*w]>0 && strong[i-radius*w-radius]>0 && strong[i+radius*w+radius]>0 && strong[i-radius*w+radius]>0 && strong[i+radius*w-radius]>0 && (alphaCutoff==240 || src.bytes[i*4+3]>252) {
    nearest[i]=Int32(i);dist[i]=0
   }
  }}
  for y in 1..<h {for x in 1..<w {let i=y*w+x;for j in [i-1,i-w] {if dist[j]+1<dist[i] {dist[i]=dist[j]+1;nearest[i]=nearest[j]}}}}
  if h>1 && w>1 {for y in stride(from:h-2,through:0,by:-1) {for x in stride(from:w-2,through:0,by:-1) {let i=y*w+x;for j in [i+1,i+w] {if dist[j]+1<dist[i] {dist[i]=dist[j]+1;nearest[i]=nearest[j]}}}}}
  var raw=src,light=src,dark=src
  raw.bytes=[UInt8](repeating:0,count:total*4);light.bytes=raw.bytes;dark.bytes=raw.bytes
  // Color treatment is evaluated on a 64 x 64 lattice and interpolated. It stays smooth
  // without doing gamut searches and pow/cbrt for every pixel of the brand mask.
  let grid=64
  var brandLight=[V](repeating:.zero,count:grid*grid),brandDark=brandLight
  if brand {
   var lightShift:Float=0,darkShift:Float=0
   for y in 0..<grid {for x in 0..<grid {
    let b=model.at(2*Float(x)/Float(grid-1)-1,2*Float(y)/Float(grid-1)-1),l=lab(b)
    lightShift=min(lightShift,lab(brandColor(b,dark:false)).x-l.x)
    darkShift=max(darkShift,lab(brandColor(b,dark:true)).x-l.x)
   }}
   for y in 0..<grid {for x in 0..<grid {
    let b=model.at(2*Float(x)/Float(grid-1)-1,2*Float(y)/Float(grid-1)-1),l=lab(b)
    brandLight[y*grid+x]=gamut(V(clamp(l.x+lightShift),l.y,l.z))
    brandDark[y*grid+x]=chromaRGB(b)<0.08 && gray(b)<0.2 ? darkNeutral(b) : gamut(V(clamp(l.x+darkShift),l.y,l.z))
   }}
  }
  func sample(_ a:[V],_ x:Int,_ y:Int)->V {
   let u=clamp(Float(x-box.x0)/Float(box.w-1))*Float(grid-1),v=clamp(Float(y-box.y0)/Float(box.h-1))*Float(grid-1)
   let ix=min(grid-2,Int(u)),iy=min(grid-2,Int(v)),fx=u-Float(ix),fy=v-Float(iy)
   return (a[iy*grid+ix]*(1-fx)+a[iy*grid+ix+1]*fx)*(1-fy)+(a[(iy+1)*grid+ix]*(1-fx)+a[(iy+1)*grid+ix+1]*fx)*fy
  }
  @inline(__always) func put(_ bytes:inout [UInt8],_ i:Int,_ c:V,_ a:Float) {
   let j=i*4;bytes[j]=UInt8(clamp(c.x)*a*255+0.5);bytes[j+1]=UInt8(clamp(c.y)*a*255+0.5);bytes[j+2]=UInt8(clamp(c.z)*a*255+0.5);bytes[j+3]=UInt8(a*255+0.5)
  }
  for y in box.y0...box.y1 {for x in box.x0...box.x1 {
   let i=y*w+x
   guard nearest[i]>=0 && dist[i]<=limit && eligible[i]>0 else {continue}
   let p=colors[i],b=bg[i]
   var f=colors[Int(nearest[i])],neutralInk:V?=nil,colourInk:V?=nil
   if resampledInk && (dist[i]>0 || invertNeutral) {
    var bestScore:Float=Float.greatestFiniteMagnitude,colourDistance=Int.max
    // Resolve nearest-seed ties by the observed colour, not scan direction.
    // The geometric term is deliberately small: it must not stamp a lobe's
    // colour into a neighbouring lobe or across overlapping ribbons.
    for dy in [-radius*2,0,radius*2] {for dx in [-radius*2,0,radius*2] {
     let xx=min(w-1,max(0,x+dx)),yy=min(h-1,max(0,y+dy)),index=Int(nearest[yy*w+xx])
     guard index>=0 else {continue}
     let candidate=colors[index],v=candidate-b,projection=dot(p-b,v)/max(0.001,dot(v,v))
     let residual=p-b-v*clamp(projection)
     let distance=abs(index%w-x)+abs(index/w-y)
     let score=dot(residual,residual)+Float(distance)*0.000001
     if score<bestScore {bestScore=score;f=candidate}
     if invertNeutral && distance<radius*5 {
      if chromaRGB(candidate)<0.08 && gray(candidate)<0.5 && (neutralInk==nil || gray(candidate)<gray(neutralInk!)) {neutralInk=candidate}
      if chromaRGB(candidate)>0.3 && distance<colourDistance {colourInk=candidate;colourDistance=distance}
     }
    }}
   }
   let d=f-b
   let projection=dot(p-b,d)/max(0.001,dot(d,d))
   var a=clamp(projection)
   // On neutral tiles, a neutral shadow must not acquire the nearest logo's hue.
   // Solve alpha in the chromatic plane as well, which cancels grey shading.
   if !colored && !invertNeutral && dist[i]>0 && protected[i]==0 {
    let dc=d-V(repeating:gray(d)), dp=p-b, pc=dp-V(repeating:gray(dp))
    if dot(dc,dc)>0.002 { a=min(a,clamp(dot(pc,dc)/dot(dc,dc))) }
   }
   if refinedMatte && !resampledInk && chromaRGB(p)>0.16 {
    // Use the most informative channel at multicolour junctions: a change of
    // hue must not be interpreted as a hole or a translucent strip.
    for c in 0..<3 where b[c]-f[c]>0.25 {a=max(a,clamp((b[c]-p[c])/(b[c]-f[c])))}
   }
   if refinedMatte && !resampledInk && chromaRGB(p)>0.16 && x>0 && x<w-1 && y>0 && y<h-1 &&
      strong[i-1]>0 && strong[i+1]>0 && strong[i-w]>0 && strong[i+w]>0 &&
      strong[i-w-1]>0 && strong[i-w+1]>0 && strong[i+w-1]>0 && strong[i+w+1]>0 {a=1}
   if dist[i]==0 || protected[i]>0 || (refinedMatte && projection>=1 && chromaRGB(p)>0.3) {a=1}
   // On a translucent plate only the opaque artwork is a reliable foreground.
   // Fade the alpha transition rather than keeping its baked, translucent shadow.
   if alphaCutoff<240 {a = clamp((Float(src.bytes[i*4+3])-247)/8)}
   if a<0.01 {continue}
   // Neutral shadows are not foreground. They have no seed, and may only survive
   // inside the narrow antialias band; noise is smoothly suppressed there.
   if dist[i]>radius*2 && a<0.25 {continue}
   // Recover the observed foreground instead of copying the nearest seed.
   // Copying it stamped rectangular colour regions across multicolour edges.
   var actual = dist[i]>0 && protected[i]==0 && alphaCutoff==240
    ? (refinedMatte ? (p-b*(1-a))/max(a,0.01) : f) : p
   if resampledInk && dist[i]>0 && protected[i]==0 {
    let residual=p-b-d*projection
    if (projection<0.995 && dot(residual,residual)<0.001) || (invertNeutral && chromaRGB(f)<0.10) {actual=f}
   }
   actual=V(clamp(actual.x),clamp(actual.y),clamp(actual.z))
   // Baked resampling rings should not become translucent dark outlines.
   // Keep fractional coverage at the silhouette, saturate near-opaque ink.
   if resampledInk && dist[i]>0 && protected[i]==0 {
    let t=clamp((a-0.08)/0.70);a=t*t*(3-2*t)
   }
   var darkActual=invertNeutral ? darkNeutral(actual):actual
   // At a neutral/coloured ink junction, invert only the neutral contribution.
   // A single foreground/background equation cannot describe three colours.
   if invertNeutral,let neutral=neutralInk,let colour=colourInk {
    let u=neutral-b,v=colour-b,q=p-b,uu=dot(u,u),vv=dot(v,v),uv=dot(u,v),det=uu*vv-uv*uv
    if det>0.01 {
     var an=(dot(q,u)*vv-dot(q,v)*uv)/det
     var ac=(dot(q,v)*uu-dot(q,u)*uv)/det
     let residual=q-u*an-v*ac
     if an > -0.025 && ac > -0.025 && an+ac<1.06 && dot(residual,residual)<0.001 {
      an=clamp(an);ac=clamp(ac);let sum=an+ac
      if sum>0.01 {
       actual=(neutral*an+colour*ac)/sum
       darkActual=(darkNeutral(neutral)*an+colour*ac)/sum
       let t=clamp((sum-0.08)/0.70);a=t*t*(3-2*t)
      }
     }
    }
   }
   if resampledInk && !invertNeutral && min(b.x,b.y,b.z)>0.7 {
    // For predominantly pure saturated ink, white contamination is measured
    // directly by the weakest channel. This preserves the observed gradient
    // instead of extending discrete seed colours through a broad bevel.
    let coverage=clamp(max((b.x-p.x)/b.x,(b.y-p.y)/b.y,(b.z-p.z)/b.z))
    if coverage>0.01 {
     actual=(p-b*(1-coverage))/coverage
     actual=V(clamp(actual.x),clamp(actual.y),clamp(actual.z));darkActual=actual
     let t=clamp((coverage-0.08)/0.70);a=t*t*(3-2*t)
    }
   }
   put(&raw.bytes,i,actual,a)
   if brand {
    put(&light.bytes,i,sample(brandLight,x,y),a);put(&dark.bytes,i,sample(brandDark,x,y),a)
   } else {
    put(&light.bytes,i,actual,a);put(&dark.bytes,i,darkActual,a)
   }
  }}
  // Multitone opaque artwork on a coloured tile can have dark internal details
  // similar to the background. Restore enclosed interiors from the original;
  // genuine holes connected to the outside remain transparent.
  if colored && !brand {
   var outside=[UInt8](repeating:0,count:total),queue=[Int]();queue.reserveCapacity(total)
   queue.append(0);outside[0]=1;var head=0
   while head<queue.count {
    let i=queue[head],x=i%w,y=i/w;head+=1
    for (xx,yy) in [(x-1,y),(x+1,y),(x,y-1),(x,y+1)] where xx>=0 && xx<w && yy>=0 && yy<h {
     let j=yy*w+xx
     if outside[j]==0 && raw.bytes[j*4+3]<250 {outside[j]=1;queue.append(j)}
    }
   }
   for y in 1..<h-1 {for x in 1..<w-1 {
    let i=y*w+x
    if outside[i]==0 && outside[i-1]==0 && outside[i+1]==0 && outside[i-w]==0 && outside[i+w]==0 && eligible[i]>0 {
     let p=colors[i]
     put(&raw.bytes,i,p,1);put(&light.bytes,i,p,1);put(&dark.bytes,i,invertNeutral ? darkNeutral(p):p,1)
    }
   }}
  }
  if resampledInk {
   let r=raw.bytes,l=light.bytes,d=dark.bytes
   for y in max(1,box.y0)...min(h-2,box.y1) {for x in max(1,box.x0)...min(w-2,box.x1) {
    let i=y*w+x,a=r[i*4+3]
    if a==r[(i-1)*4+3] && a==r[(i+1)*4+3] && a==r[(i-w)*4+3] && a==r[(i+w)*4+3] {continue}
    for c in 0..<4 {
     var sr=0,sl=0,sd=0
     for dy in -1...1 {for dx in -1...1 {
      let j=((y+dy)*w+x+dx)*4+c,weight=(dx==0 ? 2:1)*(dy==0 ? 2:1)
      sr+=Int(r[j])*weight;sl+=Int(l[j])*weight;sd+=Int(d[j])*weight
     }}
     raw.bytes[i*4+c]=UInt8((sr+8)/16);light.bytes[i*4+c]=UInt8((sl+8)/16);dark.bytes[i*4+c]=UInt8((sd+8)/16)
    }
   }}
  }
  let cleanup=cleanAlpha(&raw,&light,&dark,box,circle:isCircle)
  guard let content=cleanup.bounds else { reason="extraccion vacia; se conserva el arte"; return unchanged("extracción vacía; se conserva el arte") }
  // Mapping uses the whole plate frame. Reduce that frame about its center until
  // *all* retained alpha, including antialias pixels, fits the 0.86 safe square.
  let extentX=max(abs(CGFloat(content.x0-box.x0)/CGFloat(box.w)-0.5),abs(CGFloat(content.x1+1-box.x0)/CGFloat(box.w)-0.5))
  let extentY=max(abs(CGFloat(content.y0-box.y0)/CGFloat(box.h)-0.5),abs(CGFloat(content.y1+1-box.y0)/CGFloat(box.h)-0.5))
  let scale=min(1,0.43/max(extentX,extentY))
  let body=Lienzo.cuerpo
  let destino=CGRect(x:body.midX-body.width*scale/2,y:body.midY-body.height*scale/2,width:body.width*scale,height:body.height*scale)
  let crop=CGRect(x:box.x0,y:box.y0,width:box.w,height:box.h)
  var motivos=[String]()
  if scale<0.95 {motivos.append("logo cerca del borde; puede quedar parte del aro")}
  // La votacion de marca apenas supera el minimo de 2:1; solo cambia el diagnostico.
  if brand && lightForeground<otherForeground*3 {motivos.append("glifo de marca con votación dudosa")}
  let confianza:Confianza = motivos.isEmpty ? .alta:.media
  if motivos.isEmpty {motivos.append("ficha separada con confianza")}
  return Extraction(logo:raw.image(),light:light.image().cropping(to:crop)!,dark:dark.image().cropping(to:crop)!,destino:destino,plate:true,color:center,mode:brand ? "glifo de marca" : (invertNeutral ? "neutros aclarados en oscuro" : "colores originales"),details:String(format:"ocupacion=%.3f; error_silueta=%.4f; blancos internos=%d; votos=%d/%d; neutros=%d/%d; componentes retirados=%d; escala segura=%.4f; caja=%d,%d,%d,%d",fill,shape.error,retainedWhite,lightForeground,otherForeground,neutralMass,foregroundMass,cleanup.removed,scale,box.x0,box.y0,box.w,box.h),confianza:confianza,motivos:motivos)
 }
}

// MARK: Uso desde la app

extension Extractor {
    private static var cache: [ObjectIdentifier: (arte: CGImage, extraccion: Extraction)] = [:]
    private static let candado = NSLock()

    /// Logo de la app: de sus capas de Icon Composer si las tiene (exacto, con el oscuro del fabricante);
    /// si no, separado de la ficha por la imagen
    static func extraer(_ arte: CGImage, app: String?) -> Extraction {
        if let app, let capas = Capas.logo(app) { return desdeCapas(capas) }
        return extraer(arte)
    }

    /// El lienzo de las capas es el cuerpo de la ficha; se reduce si el logo se sale del area segura
    private static func desdeCapas(_ c: Capas.Logo) -> Extraction {
        let r = Raster(c.claro), o = Raster(c.oscuro)
        var caja = Box(x0: r.w, y0: r.h, x1: -1, y1: -1)
        for y in 0..<r.h { for x in 0..<r.w where r.bytes[(y*r.w+x)*4+3] > 8 || o.bytes[(y*o.w+x)*4+3] > 8 {
            caja.x0 = min(caja.x0, x); caja.x1 = max(caja.x1, x); caja.y0 = min(caja.y0, y); caja.y1 = max(caja.y1, y)
        }}
        let lado = CGFloat(r.w)
        let extension_ = caja.x1 < 0 ? 0.5 : max(abs(CGFloat(caja.x0)/lado-0.5), abs(CGFloat(caja.x1+1)/lado-0.5),
                                                 abs(CGFloat(caja.y0)/lado-0.5), abs(CGFloat(caja.y1+1)/lado-0.5))
        let escala = min(1, 0.43/max(0.001, extension_))
        let cuerpo = Lienzo.cuerpo
        let destino = CGRect(x: cuerpo.midX-cuerpo.width*escala/2, y: cuerpo.midY-cuerpo.height*escala/2,
                             width: cuerpo.width*escala, height: cuerpo.height*escala)
        return Extraction(logo: c.claro, light: c.claro, dark: c.oscuro, destino: destino, plate: true, color: .zero,
                          mode: "capas del icono", details: c.detalle + String(format: "; escala segura=%.4f", escala),
                          confianza: c.ocupacion > 0.6 ? .media : .alta,
                          motivos: [c.ocupacion > 0.6 ? "el logo ocupa casi todo el icono" : "logo separado por capas"])
    }

    /// Extraccion de un arte (~150 ms), guardada mientras se edita: la vista previa la pide en cada
    /// cambio del deslizador
    static func extraer(_ arte: CGImage) -> Extraction {
        let clave = ObjectIdentifier(arte)
        candado.lock()
        if let hecho = cache[clave], hecho.arte === arte {
            candado.unlock()
            return hecho.extraccion
        }
        candado.unlock()
        let entrada = arte.width == 1024 && arte.height == 1024 ? arte : (Lienzo.escalar(arte, a: 1024) ?? arte)
        let x = extract(entrada)
        candado.lock()
        if cache.count > 6 { cache.removeAll() }
        cache[clave] = (arte, x)
        candado.unlock()
        return x
    }

    /// Donde va el logo en la ficha (lo da el extractor: la ficha original mapeada al cuerpo, reducida
    /// si el logo no cabe en el area segura); `tamano` lo escala alrededor de su centro
    static func marco(_ x: Extraction, tamano: Double) -> CGRect {
        let base = x.destino
        let t = CGFloat(tamano)
        return CGRect(x: base.midX - base.width * t / 2, y: base.midY - base.height * t / 2, width: base.width * t, height: base.height * t)
    }
}
