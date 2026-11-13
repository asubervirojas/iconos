import CoreServices
import Foundation
import ObjectiveC

/// Desde macOS 26, IconServices guarda una imagen del icono de cada app por apariencia.
/// Cuando el bundle cambia (al quitar Icon\r) las descarta todas, y el Dock, al reiniciarse, solo
/// pide la de la apariencia de ese momento. En el siguiente cambio de apariencia pide la otra;
/// iconservices le da una provisional mientras la genera y el Dock se queda con la que tenia. El
/// icono restaurado no sigue el modo claro/oscuro hasta el cambio siguiente o hasta que el Dock se
/// reinicia (visto con Chrome: restaurado en claro, se quedo claro al pasar a oscuro).
///
/// Pedir aqui las dos apariencias las deja generadas antes de ese cambio. Usa el framework privado
/// IconServices (el mismo que usa el Dock); si una version de macOS lo cambia, no hace nada
enum CacheDeIconos {
    /// Lado en puntos. iconservices sirve desde una imagen guardada los tamanos de hasta 4 veces
    /// menos, asi que estos cubren el Dock de 9 a 256 puntos
    private static let lados: [CGFloat] = [32, 64, 128, 256]
    private static let escalas: [CGFloat] = [1, 2]
    /// ISImageDescriptor.appearance: 0 clara, 1 oscura
    private static let apariencias = [0, 1]
    private static let cola = DispatchQueue(label: "io.github.asubervirojas.iconos.iconservices",
                                           qos: .userInitiated, autoreleaseFrequency: .workItem)
    private static let framework = dlopen("/System/Library/PrivateFrameworks/IconServices.framework/IconServices", RTLD_LAZY)

    /// Genera el icono actual de la app en claro y oscuro. Espera como mucho `espera` segundos (son
    /// unas decimas); si iconservices no responde, lo deja terminando en segundo plano.
    /// Devuelve false si no se pudo pedir
    @discardableResult
    static func preparar(_ ruta: String, espera: TimeInterval = 4) -> Bool {
        let hecho = DispatchSemaphore(value: 0)
        let resultado = Resultado()
        cola.async {
            resultado.pedido = pedir(ruta)
            hecho.signal()
        }
        guard hecho.wait(timeout: .now() + espera) == .success else { return false }
        return resultado.pedido
    }

    /// Solo se lee despues de la senal del semaforo
    private final class Resultado: @unchecked Sendable { var pedido = false }

    /// appearanceVariant: 0 es el estilo normal; 2 y 3 son los de cristal (transparente y tintado).
    /// Solo se piden si el usuario usa uno de esos estilos de icono
    private static var variantes: [Int] {
        let tema = UserDefaults.standard.string(forKey: "AppleIconAppearanceTheme") ?? "Regular"
        return tema.hasPrefix("Regular") ? [0] : [0, 2, 3]
    }

    private typealias Crear = @convention(c) (UnsafeRawPointer, Selector, AnyObject) -> UnsafeRawPointer?
    private typealias CrearTamano = @convention(c) (UnsafeRawPointer, Selector, CGSize, CGFloat) -> UnsafeRawPointer?
    private typealias PonerEntero = @convention(c) (AnyObject, Selector, Int) -> Void
    private typealias Preparar = @convention(c) (AnyObject, Selector, AnyObject) -> Unmanaged<AnyObject>?

    private static func pedir(_ ruta: String) -> Bool {
        guard framework != nil else { return false }
        let url = URL(fileURLWithPath: ruta, isDirectory: true)
        // noteFileSystemChanged no espera a que Launch Services vuelva a leer el bundle.
        // Renueva el registro antes de pedir a IconServices las variantes restauradas.
        _ = LSRegisterURL(url as CFURL, true)
        let conURL = NSSelectorFromString("initWithURL:"), conTamano = NSSelectorFromString("initWithSize:scale:")
        let ponerApariencia = NSSelectorFromString("setAppearance:"), ponerVariante = NSSelectorFromString("setAppearanceVariant:")
        let preparar = NSSelectorFromString("prepareImageForDescriptor:")
        guard let claseIcono = NSClassFromString("ISIcon"), let claseDescriptor = NSClassFromString("ISImageDescriptor"),
              class_getInstanceMethod(claseDescriptor, conTamano) != nil,
              class_getInstanceMethod(claseDescriptor, ponerApariencia) != nil,
              let icono = crear(claseIcono, conURL, { (imp: Crear, crudo) in imp(crudo, conURL, url as NSURL) }),
              icono.responds(to: preparar) else { return false }
        let conVariante = class_getInstanceMethod(claseDescriptor, ponerVariante) != nil
        let impPreparar = unsafeBitCast(icono.method(for: preparar), to: Preparar.self)
        for variante in conVariante ? variantes : [0] {
            for apariencia in apariencias {
                for escala in escalas {
                    for lado in lados {
                        guard let d = crear(claseDescriptor, conTamano, { (imp: CrearTamano, crudo) in
                            imp(crudo, conTamano, CGSize(width: lado, height: lado), escala)
                        }) else { return false }
                        unsafeBitCast(d.method(for: ponerApariencia), to: PonerEntero.self)(d, ponerApariencia, apariencia)
                        if conVariante, variante != 0 {
                            unsafeBitCast(d.method(for: ponerVariante), to: PonerEntero.self)(d, ponerVariante, variante)
                        }
                        _ = impPreparar(icono, preparar, d)
                    }
                }
            }
        }
        return true
    }

    /// alloc + init por el runtime de Objective-C. Con punteros crudos para que ARC no cuente de mas:
    /// init consume la referencia de alloc y devuelve otra a +1, que es la que se queda Swift
    private static func crear<Firma>(_ clase: AnyClass, _ inicializador: Selector, _ llamar: (Firma, UnsafeRawPointer) -> UnsafeRawPointer?) -> NSObject? {
        guard let reservado = (clase as AnyObject).perform(NSSelectorFromString("alloc")) else { return nil }
        let crudo = UnsafeRawPointer(reservado.toOpaque())
        // El objeto reservado puede ser de otra clase (agrupacion de clases): se pregunta a el
        guard let claseReal = object_getClass(reservado.takeUnretainedValue()),
              class_getInstanceMethod(claseReal, inicializador) != nil,
              let imp = class_getMethodImplementation(claseReal, inicializador) else {
            reservado.release()
            return nil
        }
        guard let creado = llamar(unsafeBitCast(imp, to: Firma.self), crudo) else { return nil }
        return Unmanaged<NSObject>.fromOpaque(creado).takeRetainedValue()
    }
}
