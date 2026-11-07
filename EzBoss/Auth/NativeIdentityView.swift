import SwiftUI

struct NativeIdentityView: View {
    @ObservedObject var session: Session
    @State private var mode = "login"
    @State private var email = ""
    @State private var name = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var code = ""
    @State private var backup = false
    @State private var showPassword = false
    @State private var accepted = false
    @State private var pending = false
    @State private var message = ""
    @State private var configuration: [String:Any] = [:]
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:18) {
                Image("EzBossLogo").resizable().scaledToFit().frame(width:180,height:60).accessibilityLabel("EzBoss")
                Text(mode == "mfa" ? "Verify your sign-in" : mode == "signup" ? "Create your account" : mode == "recover" ? "Reset your password" : mode == "verify" ? "Check your inbox" : "Welcome back").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                Text("Your work. All connected.").foregroundStyle(.secondary)
                if !message.isEmpty { Text(message).accessibilityLabel(message).accessibilityAddTraits(.updatesFrequently) }
                if case .failed(let reason,_) = session.state { Text(reason).foregroundStyle(.red) }
                if mode == "signup" { TextField("Full name",text:$name).textContentType(.name).autocorrectionDisabled() }
                if mode != "mfa" { TextField("Email",text:$email).textContentType(.username).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled() }
                if mode == "login" || mode == "signup" {
                    if showPassword { TextField("Password",text:$password).textContentType(mode == "login" ? .password : .newPassword).textInputAutocapitalization(.never).autocorrectionDisabled() }
                    else { SecureField("Password",text:$password).textContentType(mode == "login" ? .password : .newPassword) }
                    Toggle("Show password",isOn:$showPassword)
                }
                if mode == "signup" {
                    SecureField("Confirm password",text:$confirmation).textContentType(.newPassword)
                    Text("Use 12–128 characters. Password managers and paste are supported.").font(.footnote)
                    if let terms = configuration["termsURL"] as? String, let privacy = configuration["privacyURL"] as? String, let termsURL = URL(string:terms), let privacyURL = URL(string:privacy) {
                        HStack { Link("Terms",destination:termsURL); Link("Privacy policy",destination:privacyURL) }
                        Toggle("I accept the current terms and privacy policy",isOn:$accepted)
                    } else { Text("Account creation will be available when the legal documents are published.").font(.footnote) }
                }
                if mode == "mfa" {
                    TextField(backup ? "Recovery code" : "Authenticator code",text:$code).textContentType(.oneTimeCode).keyboardType(backup ? .default : .numberPad).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Toggle("Use a recovery code",isOn:$backup)
                }
                Button(pending || session.busy ? "Please wait…" : mode == "login" ? "Sign in" : mode == "signup" ? "Create account" : mode == "mfa" ? "Verify" : mode == "verify" ? "Resend verification" : "Send recovery link") { Task { await submit() } }
                    .buttonStyle(.borderedProminent).frame(minHeight:48).disabled(pending || session.busy || (mode == "signup" && (!accepted || configuration["termsVersion"] as? String == nil)))
                if mode == "mfa" { Button("Cancel sign-in") { _ = session.nativeCredentials?.clear(); mode = "login"; code = "" }.frame(minHeight:44) }
                else {
                    Button(mode == "signup" ? "Already have an account? Sign in" : "Create an account") { change(mode == "signup" ? "login" : "signup") }.frame(minHeight:44)
                    Button(mode == "recover" || mode == "verify" ? "Back to sign in" : "Forgot password?") { change(mode == "recover" || mode == "verify" ? "login" : "recover") }.frame(minHeight:44)
                }
                if session.nativeCredentials?.hasSession == true { Button("Retry account access") { Task { await session.restore() } }.frame(minHeight:44) }
            }.textFieldStyle(.roundedBorder).padding(24).frame(maxWidth:520)
        }.background(Color(red:0.98,green:0.98,blue:0.96)).disabled(pending || session.busy)
            .task { if let native = session.nativeCredentials, let result = try? await native.request("/ezboss/config") { configuration = result.0 } }
            .onDisappear { password = ""; confirmation = ""; code = "" }
    }
    private func change(_ value:String) { mode = value; password = ""; confirmation = ""; code = ""; message = "" }
    private func submit() async {
        guard !pending, let native = session.nativeCredentials else { return }
        pending = true; message = ""
        defer { pending = false; password = ""; confirmation = ""; code = "" }
        do {
            switch mode {
            case "login":
                let complete = try await session.nativeSignIn(email:email,password:password)
                if !complete { mode = "mfa" }
            case "mfa": _ = try await session.nativeSignIn(email:"",password:"",code:code,backup:backup)
            case "signup":
                guard password == confirmation, (12...128).contains(password.count), accepted,
                      let terms = configuration["termsVersion"] as? String, let privacy = configuration["privacyVersion"] as? String else { message = "Check the passwords and accept the current legal documents."; return }
                _ = try await native.request("/sign-up/email",body:["name":name,"email":email,"password":password,"acceptedTermsVersion":terms,"acceptedPrivacyVersion":privacy])
                mode = "verify"; message = "Check your email to verify the account, then sign in."
            case "verify":
                _ = try await native.request("/send-verification-email",body:["email":email]); message = "If verification is needed, an email will arrive shortly."
            default:
                guard let web = configuration["appOrigin"] as? String else { throw NativeAuthFailure.unavailable }
                _ = try await native.request("/request-password-reset",body:["email":email,"redirectTo":web + "/reset-password"])
                message = "If this address can be used for recovery, an email will arrive shortly."
            }
        } catch is CancellationError { }
        catch NativeAuthFailure.unavailable { message = "Authentication is temporarily unavailable. Your saved session has been kept. Retry shortly." }
        catch { message = "Sign-in could not finish. Check your details or use a new authenticator code and try again." }
    }
}

struct NativeCompanySetupView: View {
    @ObservedObject var session: Session
    @State private var firstName=""
    @State private var lastName=""
    @State private var company=""
    @State private var trades=""
    @State private var employeeCount="1"
    @State private var message=""
    @State private var webOrigin:URL?
    var body:some View {
        ScrollView { VStack(alignment:.leading,spacing:18) {
            Text("Your identity is ready").font(.largeTitle.bold())
            Text("Create a contractor company, or continue an invitation to an existing company. You can also sign out and finish later.")
            if let webOrigin { Link("Join an existing company with an invitation",destination:webOrigin.appendingPathComponent("employee-account")) }
            TextField("First name",text:$firstName).textContentType(.givenName)
            TextField("Last name",text:$lastName).textContentType(.familyName)
            TextField("Company name",text:$company).textContentType(.organizationName)
            TextField("Trade types, separated by commas",text:$trades)
            Picker("Employee count",selection:$employeeCount) { ForEach(["1","2-5","6-10","11-25","26-50","51+"],id:\.self) { Text($0) } }
            if !message.isEmpty { Text(message).foregroundStyle(.red) }
            Button("Create contractor company") { Task {
                do { try await session.createNativeCompany(["firstName":firstName,"lastName":lastName,"company":company,"employeeCount":employeeCount,"tradeTypes":trades.split(separator:",").map{$0.trimmingCharacters(in:.whitespacesAndNewlines)}.filter{!$0.isEmpty}]) }
                catch { message="Company setup was not confirmed. Retry account access before submitting again." }
            }}.buttonStyle(.borderedProminent).disabled(session.busy || firstName.isEmpty || lastName.isEmpty || trades.isEmpty)
            Button("Retry account access") { Task { await session.restore() } }.disabled(session.busy)
            Button("Sign out") { Task { await session.signOut() } }.disabled(session.busy)
        }.textFieldStyle(.roundedBorder).padding(24).frame(maxWidth:520) }
        .task { if let result=try? await session.nativeCredentials?.request("/ezboss/config"),let value=result.0["appOrigin"] as? String { webOrigin=URL(string:value) } }
    }
}
