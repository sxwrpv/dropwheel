import Foundation
import Testing
@testable import DropwheelCore

@Suite("KeyBindings")
struct KeyBindingsTests {
    @Test("Standard bindings match Shift, Command, Control")
    func standard() {
        let bindings = KeyBindings.standard
        #expect(bindings.isValid)
        #expect(bindings.wheel(for: .shift) == .conversions)
        #expect(bindings.wheel(for: .command) == .tools)
        #expect(bindings.wheel(for: .control) == .actions)
        #expect(bindings.wheel(for: .option) == nil)
    }

    @Test("Rebinding to an unused key leaves other wheels alone")
    func rebindToUnusedKey() {
        let updated = KeyBindings.standard.rebinding(.conversions, to: .option)
        #expect(updated == KeyBindings(conversions: .option, tools: .command, actions: .control))
    }

    @Test("Rebinding to a key in use swaps the two wheels")
    func rebindSwaps() {
        let updated = KeyBindings.standard.rebinding(.conversions, to: .control)
        #expect(updated == KeyBindings(conversions: .control, tools: .command, actions: .shift))
        #expect(updated.isValid)
    }

    @Test("Rebinding never mutates the original")
    func immutability() {
        let original = KeyBindings.standard
        _ = original.rebinding(.tools, to: .shift)
        #expect(original == .standard)
    }

    @Test("Duplicate keys are invalid")
    func duplicatesInvalid() {
        #expect(!KeyBindings(conversions: .shift, tools: .shift, actions: .control).isValid)
    }

    @Test("Bindings round-trip through JSON")
    func codable() throws {
        let data = try JSONEncoder().encode(KeyBindings.standard)
        let decoded = try JSONDecoder().decode(KeyBindings.self, from: data)
        #expect(decoded == .standard)
    }
}
