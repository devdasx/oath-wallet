import Foundation
import Observation

@MainActor
@Observable
final class SendRecipientNameResolutionModel {
    typealias Resolve = @Sendable (
        String,
        String
    ) async throws -> String

    private struct Input: Hashable, Sendable {
        let name: String
        let networkID: String
    }

    private enum Status: Hashable {
        case idle
        case resolving(Input)
        case resolved(Input, address: String)
        case failed(Input, error: SendRecipientNameError)
    }

    private var status = Status.idle
    @ObservationIgnored private let resolve: Resolve
    @ObservationIgnored private var scheduledResolutionTask:
        Task<Void, Never>?

    init(
        resolve: @escaping Resolve = { name, networkID in
            try await SendRecipientNameResolver.shared.resolve(
                name,
                networkID: networkID
            )
        }
    ) {
        self.resolve = resolve
    }

    func schedule(
        sourceRecipient: String,
        networkID: String,
        debounce: Duration = .milliseconds(300)
    ) {
        scheduledResolutionTask?.cancel()
        scheduledResolutionTask = nil

        guard let input = Self.resolutionInput(
            sourceRecipient: sourceRecipient,
            networkID: networkID
        ) else {
            status = .idle
            return
        }

        status = .resolving(input)
        scheduledResolutionTask = Task { [weak self] in
            do {
                try await Task.sleep(for: debounce)
                try Task.checkCancellation()
            } catch {
                return
            }
            guard let self else { return }
            await self.performResolution(input)
        }
    }

    func cancel() {
        scheduledResolutionTask?.cancel()
        scheduledResolutionTask = nil
        status = .idle
    }

    func retry() {
        guard case let .failed(input, _) = status else { return }
        status = .resolving(input)
        scheduledResolutionTask?.cancel()
        scheduledResolutionTask = Task { [weak self] in
            guard let self else { return }
            await self.performResolution(input)
        }
    }

    func waitForScheduledResolution() async {
        await scheduledResolutionTask?.value
    }

    func isResolving(
        sourceRecipient: String,
        networkID: String
    ) -> Bool {
        guard let input = Self.resolutionInput(
            sourceRecipient: sourceRecipient,
            networkID: networkID
        ) else { return false }
        guard case let .resolving(statusInput) = status,
              statusInput == input
        else { return false }
        return true
    }

    func issue(
        sourceRecipient: String,
        networkID: String
    ) -> SendRecipientNameError? {
        guard let input = Self.resolutionInput(
            sourceRecipient: sourceRecipient,
            networkID: networkID
        ) else { return nil }
        guard case let .failed(statusInput, error) = status,
              statusInput == input
        else {
            return nil
        }
        return error
    }

    func canRetry(
        sourceRecipient: String,
        networkID: String
    ) -> Bool {
        issue(
            sourceRecipient: sourceRecipient,
            networkID: networkID
        ) != nil
    }

    func validatedRecipient(
        sourceRecipient: String,
        networkID: String
    ) -> String? {
        let source = sourceRecipient.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if let input = Self.resolutionInput(
            sourceRecipient: source,
            networkID: networkID
        ) {
            guard case let .resolved(statusInput, address) = status,
                  statusInput == input
            else { return nil }
            return address
        }
        return SendAddressValidator.isValid(source, for: networkID)
            ? source : nil
    }

    private func performResolution(_ input: Input) async {
        do {
            let address = try await resolve(input.name, input.networkID)
            try Task.checkCancellation()
            guard case let .resolving(statusInput) = status,
                  statusInput == input
            else { return }
            guard SendAddressValidator.isValid(
                address,
                for: input.networkID
            ) else {
                status = .failed(
                    input,
                    error: .invalidResolvedAddress
                )
                return
            }
            status = .resolved(input, address: address)
        } catch is CancellationError {
            return
        } catch let error as SendRecipientNameError {
            guard case let .resolving(statusInput) = status,
                  statusInput == input
            else { return }
            status = .failed(input, error: error)
        } catch {
            guard case let .resolving(statusInput) = status,
                  statusInput == input
            else { return }
            status = .failed(input, error: .serviceUnavailable)
        }
    }

    private static func resolutionInput(
        sourceRecipient: String,
        networkID: String
    ) -> Input? {
        let source = sourceRecipient.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !source.isEmpty else { return nil }

        do {
            guard let descriptor = try SendRecipientNameParser.descriptor(
                for: source
            ), descriptor.candidateNetworkIDs.contains(networkID)
            else { return nil }
            return Input(name: descriptor.input, networkID: networkID)
        } catch {
            return nil
        }
    }
}
