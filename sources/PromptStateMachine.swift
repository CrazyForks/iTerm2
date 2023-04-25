//
//  PromptStateMachine.swift
//  iTerm2SharedARC
//
//  Created by George Nachman on 4/20/23.
//

import Foundation

@objc(iTermPromptStateMachineDelegate)
protocol PromptStateMachineDelegate: AnyObject {
    @objc func promptStateMachineRevealComposer(prompt: [ScreenCharArray])
    @objc func promptStateMachineDismissComposer()
    @objc func promptStateMachineLastPrompt() -> [ScreenCharArray]

    @objc(promptStateMachineAppendCommandToComposer:)
    func promptStateMachineAppendCommandToComposer(command: String)
}

@objc(iTermPromptStateMachine)
class PromptStateMachine: NSObject {
    @objc weak var delegate: PromptStateMachineDelegate?

    private enum State: CustomDebugStringConvertible {
        case disabled

        case ground
        case receivingPrompt

        // Composer is always open in this state.
        case enteringCommand(prompt: [ScreenCharArray])

        // Composer is always open in this state.
        case accruingAlreadyEnteredCommand(commandSoFar: String, prompt: [ScreenCharArray])

        case echoingBack
        case executing

        var debugDescription: String {
            switch self {
            case .disabled: return "disabled"
            case .ground: return "ground"
            case .receivingPrompt: return "receivingPrompt"
            case .enteringCommand: return "enteringCommand"
            case let .accruingAlreadyEnteredCommand(commandSoFar: commandSoFar, prompt: prompt):
                return "accruingAlreadyEnteredCommand(commandSoFar: \(commandSoFar), prompt: \(prompt))"
            case .echoingBack: return "echoingBack"
            case .executing: return "executing"
            }
        }

        private enum Name: String {
            case disabled
            case ground
            case receivingPrompt
            case enteringCommand
            case accruingAlreadyEnteredCommand
            case echoingBack
            case executing
        }

        var name: String {
            switch self {
            case .disabled:
                return Name.disabled.rawValue
            case .ground:
                return Name.ground.rawValue
            case .receivingPrompt:
                return Name.receivingPrompt.rawValue
            case .enteringCommand:
                return Name.enteringCommand.rawValue
            case .echoingBack:
                return Name.echoingBack.rawValue
            case .executing:
                return Name.executing.rawValue
            case .accruingAlreadyEnteredCommand:
                return Name.accruingAlreadyEnteredCommand.rawValue

            }
        }
        private static let nameKey = "name"
        private static let promptKey = "prompt"
        private static let commandSoFarKey = "commandSoFar"

        var dictionaryValue: [String: Any] {
            var result: [String: Any] = [State.nameKey: name]
            switch self {
            case .disabled, .ground, .receivingPrompt, .echoingBack, .executing:
                break
            case .enteringCommand(prompt: let prompt):
                result[State.promptKey] = prompt.map { $0.dictionaryValue }
            case .accruingAlreadyEnteredCommand(commandSoFar: let commandSoFar,
                                                prompt: let prompt):
                result[State.promptKey] = prompt.map { $0.dictionaryValue }
                result[State.commandSoFarKey] = commandSoFar
            }
            return result
        }

        private static func prompt(fromDictionary dictionary: NSDictionary) -> [ScreenCharArray] {
            let promptDictionaries: [[AnyHashable: Any]] = dictionary[State.promptKey] as? [[AnyHashable: Any]] ?? []
            let prompt: [ScreenCharArray] = promptDictionaries.compactMap { ScreenCharArray(dictionary: $0) }
            return prompt
        }

        init(dictionary: NSDictionary) {
            guard let name = dictionary[State.nameKey] as? String else {
                self = .ground
                return
            }
            switch Name(rawValue: name) {
            case .disabled:
                self = .disabled
            case .ground:
                self = .ground
            case .receivingPrompt:
                self = .receivingPrompt
            case .enteringCommand:
                self = .enteringCommand(prompt: Self.prompt(fromDictionary: dictionary))
            case .accruingAlreadyEnteredCommand:
                let commandSoFar = dictionary[State.commandSoFarKey] as? String ?? ""
                self = .accruingAlreadyEnteredCommand(commandSoFar: commandSoFar,
                                                      prompt: Self.prompt(fromDictionary: dictionary))
            case .echoingBack:
                self = .echoingBack
            case .executing:
                self = .executing
            case .none:
                self = .ground
            }
        }
    }

    private var _state = State.ground
    private var state: State { _state }
    private var currentEvent = ""

    private func set(state newValue: State, on event: String) {
        NSLog("\(event): \(state) -> \(newValue)")
        _state = newValue
    }

    @objc var isEnteringCommand: Bool {
        switch state {
        case .enteringCommand, .accruingAlreadyEnteredCommand:
            return true
        case .executing, .echoingBack, .receivingPrompt, .ground, .disabled:
            return false
        }
    }

    @objc(setAllowed:)
    func setAllowed(_ allowed: Bool) {
        currentEvent = "setAllowed"
        defer { currentEvent = "none" }
        if !allowed {
            set(state: .disabled, on: "disallowed")
            dismissComposer()
        } else {
            set(state: .ground, on: "allowed")
        }
    }

    // Call this before any other token handling.
    @objc(handleToken:withEncoding:)
    func handle(token: VT100Token, encoding: UInt) {
        currentEvent = "handleToken\(token.debugDescription)"
        defer { currentEvent = "none" }

        switch token.type {
        case XTERMCC_FINAL_TERM:
            handleFinalTermToken(token)
        default:
            handleToken(token, encoding: encoding)
        }
    }

    @objc
    func willSendCommand() {
        NSLog("willSendCommand in \(state)")
        currentEvent = "willSendCommand"
        defer { currentEvent = "none" }

        switch state {
        case .disabled, .ground, .receivingPrompt, .accruingAlreadyEnteredCommand, .echoingBack, .executing:
            return
        case .enteringCommand:
            set(state: .echoingBack, on: "willSendCommand")
        }
    }

    private func handleFinalTermToken(_ token: VT100Token) {
        guard let value = token.string else {
            return
        }
        let args = value.components(separatedBy: ";")
        guard let firstArg = args.first else {
            return
        }
        switch firstArg {
        case "A":
            handleFinalTermA()
        case "B":
            handleFinalTermB()
        case "C":
            handleFinalTermC()
        case "D":
            handleFinalTermD()
        default:
            break
        }
    }

    // Will receive prompt
    private func handleFinalTermA() {
        switch state {
        case .disabled:
            break
        case .ground, .echoingBack, .executing:
            set(state: .receivingPrompt, on: "A")
        case .enteringCommand:
            dismissComposer()
            set(state: .receivingPrompt, on: "A")
        case .receivingPrompt:
            break
        case .accruingAlreadyEnteredCommand:
            set(state: .receivingPrompt, on: "A")
        }
    }

    // Did receive prompt
    private func handleFinalTermB() {
        switch state {
        case .disabled:
            break
        case .receivingPrompt:
            // Expect a call to didCapturePrompt
            break
        case .enteringCommand:
            // Something crazy happened so continue without composer.
            dismissComposer()
            set(state: .ground, on: "B")
        case .ground, .echoingBack, .executing:
            // Something crazy happened so continue without composer.
            set(state: .ground, on: "B")
        case .accruingAlreadyEnteredCommand:
            // Something crazy happened so continue without composer.
            set(state: .ground, on: "B")
        }
    }

    @objc(didCapturePrompt:)
    func didCapturePrompt(promptText: [ScreenCharArray]) {
        switch state {
        case .disabled:
            break
        case .receivingPrompt:
            revealComposer(prompt: promptText)
            set(state: .enteringCommand(prompt: promptText), on: "B")
        case .enteringCommand, .ground, .echoingBack, .executing, .accruingAlreadyEnteredCommand:
            // If you get here it's probably because a trigger detected the prompt.
            revealComposer(prompt: promptText)
            set(state: .enteringCommand(prompt: promptText), on: "Trigger, probably")
            break
        }
    }

    // Command began executing
    private func handleFinalTermC() {
        switch state {
        case .disabled:
            break
        case .ground, .receivingPrompt, .executing:
            // Something crazy happened so continue without composer.
            set(state: .ground, on: "C")
        case .enteringCommand:
            // TODO: Your work will be lost.
            dismissComposer()
            set(state: .ground, on: "C")
        case .echoingBack, .accruingAlreadyEnteredCommand:
            dismissComposer()
            set(state: .executing, on: "C")
        }
    }

    // Command finished executing
    private func handleFinalTermD() {
        switch state {
        case .disabled:
            break
        case .ground, .receivingPrompt, .echoingBack, .executing, .accruingAlreadyEnteredCommand:
            set(state: .ground, on: "D")
        case .enteringCommand:
            dismissComposer()
            set(state: .ground, on: "D")
        }
    }

    // Returns whether the token should be handled immediately.
    private func handleToken(_ token: VT100Token, encoding: UInt) {
        switch state {
        case .ground, .receivingPrompt, .echoingBack, .executing, .disabled:
            return
        case .enteringCommand(let prompt):
            let command = token.stringValue(encoding: String.Encoding(rawValue: encoding)) ?? ""
            if command.isEmpty {
                // Allow stuff like focus reporting to go through.
                return
            }
            accrue(part: String(command.trimmingLeadingCharacters(in: .whitespaces)),
                   commandSoFar: "",
                   prompt: prompt)
        case .accruingAlreadyEnteredCommand(commandSoFar: let commandSoFar, let prompt):
            let part = token.stringValue(encoding: String.Encoding(rawValue: encoding)) ?? ""
            accrue(part: part, commandSoFar: commandSoFar, prompt: prompt)
        }
    }

    private func accrue(part: String, commandSoFar: String, prompt: [ScreenCharArray]) {
        set(state: .accruingAlreadyEnteredCommand(commandSoFar: commandSoFar + part,
                                                  prompt: prompt),
            on: "token")
        if !part.isEmpty {
            appendCommandToComposer(command: part)
        }
    }

    private func revealComposer(prompt: [ScreenCharArray]) {
        NSLog("revealComposer because \(currentEvent) in \(state)")
        delegate?.promptStateMachineRevealComposer(prompt: prompt)
    }

    private func dismissComposer() {
        NSLog("dismissComposer because \(currentEvent) in \(state)")
        delegate?.promptStateMachineDismissComposer()
    }

    private func lastPrompt() -> [ScreenCharArray]? {
        return delegate?.promptStateMachineLastPrompt()
    }

    private func appendCommandToComposer(command: String) {
        NSLog("appendCommandToComposer(\(command)) because \(currentEvent) in \(state)")
        delegate?.promptStateMachineAppendCommandToComposer(command: command)
    }

    @objc
    func loadPromptStateDictionary(_ dict: NSDictionary) {
        _state = State(dictionary: dict)
        switch state {
        case .disabled, .ground, .receivingPrompt, .echoingBack, .executing:
            dismissComposer()
        case .enteringCommand(let prompt):
            revealComposer(prompt: prompt)
        case .accruingAlreadyEnteredCommand(commandSoFar: let commandSoFar, prompt: let prompt):
            revealComposer(prompt: prompt)
            delegate?.promptStateMachineAppendCommandToComposer(command: commandSoFar)
        }
    }

    @objc
    var dictionaryValue: NSDictionary {
        return state.dictionaryValue as NSDictionary
    }
}


extension VT100Token {
    func stringValue(encoding: String.Encoding) -> String? {
        switch type {
        case VT100_STRING:
            return self.string
        case VT100_ASCIISTRING:
            let data = NSData(bytes: asciiData.pointee.buffer, length: Int(asciiData.pointee.length))
            return String(data: data as Data, encoding: encoding)
        case VT100CC_LF:
            return "\n"
        default:
            return nil
        }
    }
}
