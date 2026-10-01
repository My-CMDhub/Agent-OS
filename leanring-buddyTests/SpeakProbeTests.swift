import Testing
@testable import Clicky

@Suite struct SpeakProbeTests {
    @Test func openAISystemTurnAsksForAReplyOnlyInTheCreateVariant() {
        let only = RealtimeVoiceConnection.systemTurnMessages(stack: .openAIRealtime, text: "Step 2 done.", variant: .textOnly)
        #expect(only.count == 1)
        #expect(only[0]["type"] as? String == "conversation.item.create")
        let create = RealtimeVoiceConnection.systemTurnMessages(stack: .openAIRealtime, text: "Step 2 done.", variant: .textThenCreate)
        #expect(create.map { $0["type"] as? String } == ["conversation.item.create", "response.create"])
    }

    @Test func geminiSystemTurnUsesRealtimeTextOrAClosedClientTurn() {
        let text = RealtimeVoiceConnection.systemTurnMessages(stack: .geminiLive, text: "Step 2 done.", variant: .textOnly)
        #expect((text[0]["realtimeInput"] as? [String: Any])?["text"] as? String == "Step 2 done.")
        let client = RealtimeVoiceConnection.systemTurnMessages(stack: .geminiLive, text: "Step 2 done.", variant: .clientContent)
        let content = client[0]["clientContent"] as? [String: Any]
        #expect(content?["turnComplete"] as? Bool == true)
    }
}
