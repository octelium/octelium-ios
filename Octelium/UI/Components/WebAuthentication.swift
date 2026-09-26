import AuthenticationServices
import OcteliumCore
import SwiftUI

struct LoginOpener {
    let open: (String, String) -> Void

    func callAsFunction(_ url: String, _ domain: String) {
        open(url, domain)
    }
}

private struct LoginOpenerKey: EnvironmentKey {
    static let defaultValue = LoginOpener { _, _ in }
}

extension EnvironmentValues {
    var openLogin: LoginOpener {
        get { self[LoginOpenerKey.self] }
        set { self[LoginOpenerKey.self] = newValue }
    }
}

struct WebAuthenticationProvider: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    func body(content: Content) -> some View {
        content.environment(\.openLogin, LoginOpener { url, domain in
            Task {
                await authenticate(url, domain)
            }
        })
    }

    @MainActor
    private func authenticate(_ url: String, _ domain: String) async {
        guard isLoginURLAllowed(url), let loginURL = URL(string: url) else {
            model.setAuthCallbackError("Refusing to open a non-HTTPS URL")
            return
        }

        do {
            let callbackURL = try await webAuthenticationSession.authenticate(
                using: loginURL,
                callbackURLScheme: authCallbackScheme
            )
            model.handleAuthCallback(callbackURL)
        } catch let err as ASWebAuthenticationSessionError where err.code == .canceledLogin {
            await model.cancelAuthentication(domain)
        } catch {
            model.setAuthCallbackError(getErrorMessage(error))
        }
    }
}

extension View {
    func webAuthenticationProvider() -> some View {
        modifier(WebAuthenticationProvider())
    }
}
