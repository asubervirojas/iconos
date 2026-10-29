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
  func unchanged() -> Extraction {
   // Existing freeform path: crop all visible alpha, then use the original maximum side of 0.64.
   var b=Box(x0:w,y0:h,x1:0,y1:0)
   for y in 0..<h {for x in 0..<w where src.bytes[(y*w+x)*4+3]>12 {b.x0=min(x,b.x0);b.x1=max(x,b.x1);b.y0=min(y,b.y0);b.y1=max(y,b.y1)}}
   if b.x0 > b.x1 || b.y0 > b.y1 { b=Box(x0:0,y0:0,x1:w-1,y1:h-1) }
   let crop=image.cropping(to:CGRect(x:b.x0,y:b.y0,width:b.w,height:b.h))!
   let factor=0.64*1024/CGFloat(max(b.w,b.h))
   let destino=CGRect(x:512-CGFloat(b.w)*factor/2,y:512-CGFloat(b.h)*factor/2,width:CGFloat(b.w)*factor,height:CGFloat(b.h)*factor)
   return Extraction(logo:image,light:crop,dark:crop,destino:destino,plate:false,color:.zero,mode:"arte completo",details:String(format:"ocupacion=%.3f; error_silueta=%.4f; %@",fill,shape.error,reason))
  }
  if !isPlate {return unchanged()}
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
  if samples.count<64 || Float(inliers)/Float(samples.count)<0.85 {reason += String(format:"; muestras=%d; ajuste=%.3f",samples.count,Float(inliers)/Float(max(1,samples.count)));return unchanged()}
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
  // Preserve white ink inside colored emblems, but punch out neutral holes (Notebook, knot, G).
  // Components attached to the plate background are always removed.
  var retainedWhite=0
  var protected=[UInt8](repeating:0,count:total)
  if !colored {
   var visited=[UInt8](repeating:0,count:total),queue=[Int]();queue.reserveCapacity(total)
   for start in 0..<total where white[start]>0 && visited[start]==0 {
    queue.removeAll(keepingCapacity:true);queue.append(start);visited[start]=1
    var head=0,touches=false,boundary=0,colorBoundary=0
    while head<queue.count {
     let i=queue[head];head+=1;let x=i%w,y=i/w
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
    if !touches && Float(queue.count)<Float(box.w*box.h)*0.08 && colorBoundary>boundary*2/3 {
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
  var neutralMass=0,chromaticMass=0,foregroundMass=0
  if !brand {for i in 0..<total where strong[i]>0 {
   let p=colors[i];foregroundMass+=1
   if chromaRGB(p)<0.16 && gray(p)<0.65 {neutralMass+=1}
   if chromaRGB(p)>0.16 {chromaticMass+=1}
  }}
  let invertNeutral=neutralMass>total/500 && (colored
   ? chromaRGB(center)>0.15 && Float(neutralMass)>Float(foregroundMass)*0.65 && neutralMass>chromaticMass*3
   : Float(neutralMass)>Float(chromaticMass)*0.12)
  // Reliable foreground samples are eroded by 4 px for glyphs / neutral ink,
  // or 12 px for colored emblems (avoids sampling the original pale drop shadow)., then extended by a
  // two-pass nearest-seed transform. This solves C = alpha F + (1-alpha) B at edges.
  let radius = !colored && !invertNeutral ? 12 : 4
  if box.w<=radius*2 || box.h<=radius*2 {reason="ficha demasiado pequena";return unchanged()}
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
    brandDark[y*grid+x]=gamut(V(clamp(l.x+darkShift),l.y,l.z))
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
   let p=colors[i],b=bg[i],f=colors[Int(nearest[i])],d=f-b
   var a=clamp(dot(p-b,d)/max(0.001,dot(d,d)))
   // On neutral tiles, a neutral shadow must not acquire the nearest logo's hue.
   // Solve alpha in the chromatic plane as well, which cancels grey shading.
   if !colored && !invertNeutral && dist[i]>0 && protected[i]==0 {
    let dc=d-V(repeating:gray(d)), dp=p-b, pc=dp-V(repeating:gray(dp))
    if dot(dc,dc)>0.002 { a=min(a,clamp(dot(pc,dc)/dot(dc,dc))) }
   }
   if dist[i]==0 || protected[i]>0 {a=1}
   // On a translucent plate only the opaque artwork is a reliable foreground.
   // Fade the alpha transition rather than keeping its baked, translucent shadow.
   if alphaCutoff<240 {a = clamp((Float(src.bytes[i*4+3])-247)/8)}
   if a<0.01 {continue}
   // Neutral shadows are not foreground. They have no seed, and may only survive
   // inside the narrow antialias band; noise is smoothly suppressed there.
   if dist[i]>radius*2 && a<0.25 {continue}
   var actual = dist[i]>0 && protected[i]==0 && alphaCutoff==240 ? f : p
   actual=V(clamp(actual.x),clamp(actual.y),clamp(actual.z))
   put(&raw.bytes,i,actual,a)
   if brand {
    put(&light.bytes,i,sample(brandLight,x,y),a);put(&dark.bytes,i,sample(brandDark,x,y),a)
   } else {
    put(&light.bytes,i,actual,a);put(&dark.bytes,i,invertNeutral ? darkNeutral(actual) : actual,a)
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
  let cleanup=cleanAlpha(&raw,&light,&dark,box,circle:isCircle)
  guard let content=cleanup.bounds else { reason="extraccion vacia; se conserva el arte"; return unchanged() }
  // Mapping uses the whole plate frame. Reduce that frame about its center until
  // *all* retained alpha, including antialias pixels, fits the 0.86 safe square.
  let extentX=max(abs(CGFloat(content.x0-box.x0)/CGFloat(box.w)-0.5),abs(CGFloat(content.x1+1-box.x0)/CGFloat(box.w)-0.5))
  let extentY=max(abs(CGFloat(content.y0-box.y0)/CGFloat(box.h)-0.5),abs(CGFloat(content.y1+1-box.y0)/CGFloat(box.h)-0.5))
  let scale=min(1,0.43/max(extentX,extentY))
  let body=Lienzo.cuerpo
  let destino=CGRect(x:body.midX-body.width*scale/2,y:body.midY-body.height*scale/2,width:body.width*scale,height:body.height*scale)
  let crop=CGRect(x:box.x0,y:box.y0,width:box.w,height:box.h)
  return Extraction(logo:raw.image(),light:light.image().cropping(to:crop)!,dark:dark.image().cropping(to:crop)!,destino:destino,plate:true,color:center,mode:brand ? "glifo de marca" : (invertNeutral ? "neutros aclarados en oscuro" : "colores originales"),details:String(format:"ocupacion=%.3f; error_silueta=%.4f; blancos internos=%d; votos=%d/%d; neutros=%d/%d; componentes retirados=%d; escala segura=%.4f; caja=%d,%d,%d,%d",fill,shape.error,retainedWhite,lightForeground,otherForeground,neutralMass,foregroundMass,cleanup.removed,scale,box.x0,box.y0,box.w,box.h))
 }
}

