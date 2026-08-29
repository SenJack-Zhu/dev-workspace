import FlutterMacOS

public final class NativeTavernLive2DMacosPlugin: NSObject, FlutterPlugin {
    private let textureRegistry: FlutterTextureRegistry
    private var textures: [Int64: Live2DMacOSTexture] = [:]

    private init(textureRegistry: FlutterTextureRegistry) {
        self.textureRegistry = textureRegistry
        super.init()
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = NativeTavernLive2DMacosPlugin(
            textureRegistry: registrar.textures)
        let channel = FlutterMethodChannel(
            name: "native_tavern_live2d_macos",
            binaryMessenger: registrar.messenger)
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let arguments = call.arguments as? [String: Any]

        switch call.method {
        case "getPlatformVersion":
            result("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        case "getTempDirectory":
            result(NSTemporaryDirectory())
        case "createTexture":
            guard let width = requireInt(arguments, "width", result: result),
                  let height = requireInt(arguments, "height", result: result)
            else { return }
            guard let texture = Live2DMacOSTexture(
                registry: textureRegistry,
                width: width,
                height: height)
            else {
                result(FlutterError(
                    code: "TEXTURE_CREATE_FAILED",
                    message: "Unable to create the Live2D offscreen renderer",
                    details: nil))
                return
            }
            let textureId = textureRegistry.register(texture)
            guard textureId != 0 else {
                texture.dispose()
                result(FlutterError(
                    code: "TEXTURE_REGISTER_FAILED",
                    message: "Flutter rejected the Live2D texture registration",
                    details: nil))
                return
            }
            textures[textureId] = texture
            texture.start(textureId: textureId)
            result(textureId)
        case "resizeTexture":
            guard let texture = requireTexture(arguments, result: result),
                  let width = requireInt(arguments, "width", result: result),
                  let height = requireInt(arguments, "height", result: result)
            else { return }
            guard texture.resize(width: width, height: height) else {
                result(FlutterError(
                    code: "TEXTURE_RESIZE_FAILED",
                    message: "Unable to resize the Live2D offscreen renderer",
                    details: nil))
                return
            }
            result(nil)
        case "disposeTexture":
            guard let textureId = requireTextureId(arguments, result: result) else {
                return
            }
            guard let texture = textures.removeValue(forKey: textureId) else {
                result(FlutterError(
                    code: "TEXTURE_NOT_FOUND",
                    message: "No Live2D texture registered for id \(textureId)",
                    details: nil))
                return
            }
            texture.dispose()
            result(nil)
        case "loadModel":
            guard let texture = requireTexture(arguments, result: result),
                  let modelDir = requireString(arguments, "modelDir", result: result),
                  let fileName = requireString(arguments, "modelFileName", result: result)
            else { return }
            result(texture.loadModel(modelDir: modelDir, fileName: fileName))
        case "unloadModel":
            guard let texture = requireTexture(arguments, result: result) else { return }
            texture.unloadModel()
            result(nil)
        case "setRenderingPaused":
            guard let texture = requireTexture(arguments, result: result),
                  let paused = arguments?["paused"] as? Bool else {
                result(invalidArguments("Missing 'paused'"))
                return
            }
            texture.setRenderingPaused(paused)
            result(nil)
        case "startMotion":
            guard let texture = requireTexture(arguments, result: result),
                  let group = arguments?["group"] as? String else {
                result(invalidArguments("Missing 'group'"))
                return
            }
            let index = (arguments?["index"] as? NSNumber)?.int32Value ?? 0
            let priority = (arguments?["priority"] as? NSNumber)?.int32Value ?? 2
            texture.startMotion(group: group, index: index, priority: priority)
            result(nil)
        case "setExpression":
            guard let texture = requireTexture(arguments, result: result) else { return }
            let index = (arguments?["index"] as? NSNumber)?.int32Value ?? 0
            texture.setExpression(index: index)
            result(nil)
        case "setParameter":
            guard let texture = requireTexture(arguments, result: result),
                  let parameterId = requireString(
                    arguments,
                    "parameterId",
                    result: result)
            else { return }
            let value = (arguments?["value"] as? NSNumber)?.floatValue ?? 0
            texture.setParameter(parameterId: parameterId, value: value)
            result(nil)
        case "setMotionSpeed":
            guard let texture = requireTexture(arguments, result: result) else { return }
            let speed = (arguments?["speed"] as? NSNumber)?.floatValue ?? 1
            texture.setMotionSpeed(speed)
            result(nil)
        case "touchBegan", "touchMoved", "touchEnded":
            guard let texture = requireTexture(arguments, result: result),
                  let x = (arguments?["x"] as? NSNumber)?.floatValue,
                  let y = (arguments?["y"] as? NSNumber)?.floatValue else {
                result(invalidArguments("Missing touch coordinates"))
                return
            }
            if call.method == "touchBegan" {
                texture.touchBegan(x: x, y: y)
            } else if call.method == "touchMoved" {
                texture.touchMoved(x: x, y: y)
            } else {
                texture.touchEnded(x: x, y: y)
            }
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func requireTexture(
        _ arguments: [String: Any]?,
        result: @escaping FlutterResult
    ) -> Live2DMacOSTexture? {
        guard let textureId = requireTextureId(arguments, result: result) else {
            return nil
        }
        guard let texture = textures[textureId] else {
            result(FlutterError(
                code: "TEXTURE_NOT_FOUND",
                message: "No Live2D texture registered for id \(textureId)",
                details: nil))
            return nil
        }
        return texture
    }

    private func requireTextureId(
        _ arguments: [String: Any]?,
        result: @escaping FlutterResult
    ) -> Int64? {
        guard let textureId = (arguments?["textureId"] as? NSNumber)?.int64Value else {
            result(invalidArguments("Missing 'textureId'"))
            return nil
        }
        return textureId
    }

    private func requireInt(
        _ arguments: [String: Any]?,
        _ name: String,
        result: @escaping FlutterResult
    ) -> Int32? {
        guard let value = (arguments?[name] as? NSNumber)?.int32Value,
              value > 0 else {
            result(invalidArguments("Missing or invalid '\(name)'"))
            return nil
        }
        return value
    }

    private func requireString(
        _ arguments: [String: Any]?,
        _ name: String,
        result: @escaping FlutterResult
    ) -> String? {
        guard let value = arguments?[name] as? String, !value.isEmpty else {
            result(invalidArguments("Missing or empty '\(name)'"))
            return nil
        }
        return value
    }

    private func invalidArguments(_ message: String) -> FlutterError {
        FlutterError(code: "INVALID_ARGS", message: message, details: nil)
    }

    deinit {
        for texture in textures.values {
            texture.dispose()
        }
    }
}
