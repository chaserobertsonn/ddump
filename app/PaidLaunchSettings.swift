import SwiftUI

struct PaidLaunchSettings: View {
  @ObservedObject private var runtime = PaidLaunchRuntime.shared
  @State private var email = ""
  @State private var confirmDeletion = false

  var body: some View {
    Form {
      Section("DDump account") {
        LabeledContent("Status", value: runtime.sessionState)
        if !runtime.accountID.isEmpty {
          LabeledContent("Account ID") {
            Text(runtime.accountID)
              .font(.system(size: 11, design: .monospaced))
              .textSelection(.enabled)
          }
        }
        if runtime.sessionState == "Signed out" || runtime.sessionState == "Check your email" {
          TextField("Email address", text: $email)
          Button {
            runtime.beginSignIn(email: email)
          } label: {
            Label("Email me a secure sign-in link", systemImage: "envelope.badge.shield.half.filled")
          }
          .buttonStyle(DDumpPrimaryButtonStyle())
          .disabled(runtime.busy || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          Text("The link opens through your browser and returns to DDump. Session and refresh material stay in this Mac's Keychain.")
            .font(.caption)
            .foregroundColor(.secondary)
        }
      }

      Section("Plans and hosted checkout") {
        if runtime.packages.isEmpty {
          Text("Sign in and refresh to load the currently approved RevenueCat offering and paywall variant.")
            .font(.caption)
            .foregroundColor(.secondary)
        }
        ForEach(runtime.packages) { package in
          VStack(alignment: .leading, spacing: 6) {
            HStack {
              VStack(alignment: .leading, spacing: 2) {
                Text(package.displayName)
                  .font(.headline)
                Text("\(package.displayAmount) · \(package.cadence)")
                  .font(.subheadline)
              }
              Spacer()
              Button("Continue in browser") {
                runtime.beginCheckout(package: package)
              }
              .buttonStyle(DDumpPrimaryButtonStyle())
              .disabled(runtime.busy)
            }
            disclosure("Trial", package.trialDisclosure)
            disclosure("Renewal", package.renewalDisclosure)
            disclosure("Tax", package.taxDisclosure)
            disclosure("Cancel", package.cancellationDisclosure)
          }
          .padding(.vertical, 5)
        }
        Text("DDump never collects card details. RevenueCat's hosted page shows and processes checkout in your system browser.")
          .font(.caption)
          .foregroundColor(.secondary)
      }

      Section("Purchases and access") {
        LabeledContent("Entitlement", value: runtime.entitlementState)
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 8) { accountButtons }
          VStack(alignment: .leading, spacing: 8) { accountButtons }
        }
        Text("Billing can block only the start of a new import at verified safe idle. It cannot interrupt card work, eject a card, or remove access to existing files, receipts, logs, diagnostics, settings, support, or safe cleanup.")
          .font(.caption)
          .foregroundColor(.secondary)
      }

      if runtime.billingLabVisible {
        Section("Billing Lab — beta/debug only") {
          LabeledContent("Environment", value: runtime.environmentLabel)
          LabeledContent("Build flavor", value: runtime.buildFlavorLabel)
          LabeledContent("Offering", value: runtime.offeringID.isEmpty ? "Not loaded" : runtime.offeringID)
          LabeledContent("Variant", value: runtime.variantID.isEmpty ? "Not loaded" : runtime.variantID)
          if !runtime.experimentID.isEmpty {
            LabeledContent("Experiment", value: runtime.experimentID)
          }
          LabeledContent("Products", value: runtime.packages.map(\.productID).joined(separator: ", "))
          LabeledContent("Entitlement", value: runtime.entitlementState)
          if !runtime.availableTestVariants.isEmpty {
            Text("Approved test variants")
              .font(.caption.weight(.semibold))
            ForEach(runtime.availableTestVariants) { variant in
              HStack {
                Text(variant.label)
                  .font(.system(size: 11, design: .monospaced))
                Spacer()
                Button("Use") { runtime.setBillingLabOverride(variant) }
                  .disabled(runtime.busy || (
                    runtime.offeringID == variant.offeringID &&
                    runtime.variantID == variant.variantID
                  ))
              }
            }
          }
          if !runtime.availableTestScenarios.isEmpty {
            Text("Approved test scenarios")
              .font(.caption.weight(.semibold))
              .padding(.top, 4)
            LazyVGrid(
              columns: [GridItem(.adaptive(minimum: 145), spacing: 6)],
              spacing: 6
            ) {
              ForEach(runtime.availableTestScenarios, id: \.self) { scenario in
                Button(scenario.replacingOccurrences(of: "_", with: " ").capitalized) {
                  runtime.runBillingLabScenario(scenario)
                }
                .buttonStyle(DDumpSecondaryButtonStyle())
                .disabled(runtime.busy)
              }
            }
          }
          Text("This lab exposes identifiers and state only—never secrets. Stable builds omit the lab. Approved test variants remain constrained by the backend catalog and cannot alter ingest behavior.")
            .font(.caption)
            .foregroundColor(.secondary)
        }
      }

      Section("Account controls") {
        Button("Sign out") { runtime.signOut() }
          .disabled(runtime.busy || runtime.sessionState == "Signed out")
        Button("Request account deletion", role: .destructive) {
          confirmDeletion = true
        }
        .disabled(runtime.busy || runtime.sessionState == "Signed out")
      }

      if !runtime.statusMessage.isEmpty {
        Section("Status") {
          HStack(alignment: .top, spacing: 8) {
            if runtime.busy { ProgressView().controlSize(.small) }
            Text(runtime.statusMessage)
              .font(.caption)
              .textSelection(.enabled)
          }
        }
      }
    }
    .alert("Request account deletion?", isPresented: $confirmDeletion) {
      Button("Cancel", role: .cancel) {}
      Button("Submit request", role: .destructive) { runtime.requestAccountDeletion() }
    } message: {
      Text("This opens a verified deletion workflow. Required billing and audit records follow the approved retention policy; DDump never deletes your customer files.")
    }
  }

  @ViewBuilder
  private var accountButtons: some View {
    Button("Refresh") { runtime.refreshAccount() }
      .buttonStyle(DDumpSecondaryButtonStyle())
      .disabled(runtime.busy)
    Button("Restore purchases") { runtime.restorePurchases() }
      .buttonStyle(DDumpPrimaryButtonStyle())
      .disabled(runtime.busy)
    if runtime.portalAvailable {
      Button("Customer portal") { runtime.openCustomerPortal() }
        .buttonStyle(DDumpSecondaryButtonStyle())
        .disabled(runtime.busy)
    }
  }

  private func disclosure(_ label: String, _ text: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text("\(label):")
        .font(.caption.weight(.semibold))
      Text(text)
        .font(.caption)
        .foregroundColor(.secondary)
    }
  }
}
