//
// Copyright © 2022 Stream.io Inc. All rights reserved.
//

import Combine
import Photos
import StreamChat
import SwiftUI

/// View model for the `MessageComposerView`.
open class MessageComposerViewModel: ObservableObject {
    @Injected(\.chatClient) private var chatClient
    @Injected(\.utils) private var utils
    
    @Published public var pickerState: AttachmentPickerState = .photos {
        didSet {
            if pickerState == .camera {
                withAnimation {
                    cameraPickerShown = true
                }
            } else if pickerState == .files {
                withAnimation {
                    filePickerShown = true
                }
            }
        }
    }
    
    @Published private(set) var imageAssets: PHFetchResult<PHAsset>?
    @Published private(set) var addedAssets = [AddedAsset]() {
        didSet {
            checkPickerSelectionState()
        }
    }
    
    @Published public var text = "" {
        didSet {
            if text != "" {
                checkTypingSuggestions()
                if pickerTypeState != .collapsed {
                    if composerCommand == nil {
                        withAnimation {
                            pickerTypeState = .collapsed
                        }
                    } else {
                        pickerTypeState = .collapsed
                    }
                }
                channelController.sendKeystrokeEvent()
            } else {
                if composerCommand?.displayInfo?.isInstant == false {
                    composerCommand = nil
                }
                selectedRangeLocation = 0
                suggestions = [String: Any]()
            }
        }
    }

    @Published public var selectedRangeLocation: Int = 0
    
    @Published public var addedFileURLs = [URL]() {
        didSet {
            if totalAttachmentsCount > chatClient.config.maxAttachmentCountPerMessage
                || !checkAttachmentSize(with: addedFileURLs.last) {
                addedFileURLs.removeLast()
            }
            checkPickerSelectionState()
        }
    }

    @Published public var addedCustomAttachments = [CustomAttachment]() {
        didSet {
            checkPickerSelectionState()
        }
    }
    
    @Published public var pickerTypeState: PickerTypeState = .expanded(.none) {
        didSet {
            switch pickerTypeState {
            case let .expanded(attachmentPickerType):
                overlayShown = attachmentPickerType == .media || attachmentPickerType == .custom
                if attachmentPickerType == .instantCommands {
                    composerCommand = ComposerCommand(
                        id: "instantCommands",
                        typingSuggestion: TypingSuggestion.empty,
                        displayInfo: nil
                    )
                    showTypingSuggestions()
                } else {
                    composerCommand = nil
                }
            case .collapsed:
                log.debug("Collapsed state shown, no changes to overlay.")
            }
        }
    }
    
    @Published private(set) var overlayShown = false {
        didSet {
            if overlayShown == true {
                resignFirstResponder()
            }
        }
    }

    @Published public var composerCommand: ComposerCommand? {
        didSet {
            if oldValue?.id != composerCommand?.id &&
                composerCommand?.displayInfo?.isInstant == true {
                clearText()
            }
            if oldValue != nil && composerCommand == nil {
                pickerTypeState = .expanded(.none)
            }
        }
    }
    
    @Published public var filePickerShown = false
    @Published public var cameraPickerShown = false
    @Published public var errorShown = false
    @Published public var showReplyInChannel = false
    @Published public var suggestions = [String: Any]()
    @Published public var cooldownDuration: Int = 0
    
    private let channelController: ChatChannelController
    private var messageController: ChatMessageController?
    
    private var timer: Timer?
    private var cooldownPeriod = 0
    
    private var cancellables = Set<AnyCancellable>()
    private lazy var commandsHandler = utils
        .commandsConfig
        .makeCommandsHandler(
            with: channelController
        )
    
    private var messageText: String {
        if let composerCommand = composerCommand,
           let displayInfo = composerCommand.displayInfo,
           displayInfo.isInstant == true {
            return "\(composerCommand.id) \(text)"
        } else {
            return text
        }
    }
    
    private var totalAttachmentsCount: Int {
        addedAssets.count +
            addedCustomAttachments.count +
            addedFileURLs.count
    }
    
    private var canAddAdditionalAttachments: Bool {
        totalAttachmentsCount < chatClient.config.maxAttachmentCountPerMessage
    }
    
    public init(
        channelController: ChatChannelController,
        messageController: ChatMessageController?
    ) {
        self.channelController = channelController
        self.messageController = messageController
        listenToCooldownUpdates()
    }
    
    public func sendMessage(
        quotedMessage: ChatMessage?,
        editedMessage: ChatMessage?,
        completion: @escaping () -> Void
    ) {
        defer {
            checkChannelCooldown()
        }
        
        if let composerCommand = composerCommand {
            commandsHandler.executeOnMessageSent(
                composerCommand: composerCommand
            ) { [weak self] _ in
                self?.clearInputData()
                completion()
            }
            
            if composerCommand.replacesMessageSent {
                return
            }
        }
        
        if let editedMessage = editedMessage {
            edit(message: editedMessage, completion: completion)
            return
        }
        
        do {
            var attachments = try addedAssets.map { added in
                try AnyAttachmentPayload(
                    localFileURL: added.url,
                    attachmentType: added.type == .video ? .video : .image
                )
            }
            
            attachments += try addedFileURLs.map { url in
                _ = url.startAccessingSecurityScopedResource()
                return try AnyAttachmentPayload(localFileURL: url, attachmentType: .file)
            }
            
            attachments += addedCustomAttachments.map { attachment in
                attachment.content
            }
            
            if let messageController = messageController {
                messageController.createNewReply(
                    text: messageText,
                    attachments: attachments,
                    showReplyInChannel: showReplyInChannel,
                    quotedMessageId: quotedMessage?.id
                ) { [weak self] in
                    switch $0 {
                    case .success:
                        completion()
                    case .failure:
                        self?.errorShown = true
                    }
                }
            } else {
                channelController.createNewMessage(
                    text: messageText,
                    attachments: attachments,
                    quotedMessageId: quotedMessage?.id
                ) { [weak self] in
                    switch $0 {
                    case .success:
                        completion()
                    case .failure:
                        self?.errorShown = true
                    }
                }
            }
            
            clearInputData()
        } catch {
            errorShown = true
        }
    }
    
    public var sendButtonEnabled: Bool {
        if let composerCommand = composerCommand,
           let handler = commandsHandler.commandHandler(for: composerCommand) {
            return handler
                .canBeExecuted(composerCommand: composerCommand)
        }
        
        return !addedAssets.isEmpty ||
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !addedFileURLs.isEmpty ||
            !addedCustomAttachments.isEmpty
    }
    
    public var sendInChannelShown: Bool {
        messageController != nil
    }
    
    public var isDirectChannel: Bool {
        channelController.channel?.isDirectMessageChannel ?? false
    }
    
    public var showCommandsOverlay: Bool {
        let commandAvailable = composerCommand != nil
        let configuredCommandsAvailable = channelController.channel?.config.commands.count ?? 0 > 0
        return commandAvailable && configuredCommandsAvailable
    }
    
    public func change(pickerState: AttachmentPickerState) {
        if pickerState != self.pickerState {
            self.pickerState = pickerState
        }
    }
    
    public var inputComposerShouldScroll: Bool {
        if addedCustomAttachments.count > 3 {
            return true
        }
        
        if addedFileURLs.count > 2 {
            return true
        }
        
        if addedFileURLs.count == 2 && !addedAssets.isEmpty {
            return true
        }
        
        return false
    }
    
    public func imageTapped(_ addedAsset: AddedAsset) {
        var images = [AddedAsset]()
        var imageRemoved = false
        for image in addedAssets {
            if image.id != addedAsset.id {
                images.append(image)
            } else {
                imageRemoved = true
            }
        }
        
        if !imageRemoved && canAddAttachment(with: addedAsset.url) {
            images.append(addedAsset)
        }
        
        addedAssets = images
    }
    
    public func removeAttachment(with id: String) {
        if id.isURL, let url = URL(string: id) {
            var urls = [URL]()
            for added in addedFileURLs {
                if url != added {
                    urls.append(added)
                }
            }
            addedFileURLs = urls
        } else {
            var images = [AddedAsset]()
            for image in addedAssets {
                if image.id != id {
                    images.append(image)
                }
            }
            addedAssets = images
        }
    }
    
    public func cameraImageAdded(_ image: AddedAsset) {
        if canAddAttachment(with: image.url) {
            addedAssets.append(image)
        }
        pickerState = .photos
    }
    
    public func isImageSelected(with id: String) -> Bool {
        for image in addedAssets {
            if image.id == id {
                return true
            }
        }
        
        return false
    }
    
    public func customAttachmentTapped(_ attachment: CustomAttachment) {
        var temp = [CustomAttachment]()
        var attachmentRemoved = false
        for existing in addedCustomAttachments {
            if existing.id != attachment.id {
                temp.append(existing)
            } else {
                attachmentRemoved = true
            }
        }
        
        if !attachmentRemoved && canAddAdditionalAttachments {
            temp.append(attachment)
        }
        
        addedCustomAttachments = temp
    }
    
    public func isCustomAttachmentSelected(_ attachment: CustomAttachment) -> Bool {
        for existing in addedCustomAttachments {
            if existing.id == attachment.id {
                return true
            }
        }
        
        return false
    }
    
    public func askForPhotosPermission() {
        PHPhotoLibrary.requestAuthorization { (status) in
            switch status {
            case .authorized, .limited:
                log.debug("Access to photos granted.")
                let fetchOptions = PHFetchOptions()
                fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                let assets = PHAsset.fetchAssets(with: fetchOptions)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.imageAssets = assets
                }
            case .denied, .restricted, .notDetermined:
                DispatchQueue.main.async { [weak self] in
                    self?.imageAssets = PHFetchResult<PHAsset>()
                }
                log.debug("Access to photos is denied or not determined, showing the no permissions screen.")
            @unknown default:
                log.debug("Unknown authorization status.")
            }
        }
    }
    
    public func handleCommand(
        for text: Binding<String>,
        selectedRangeLocation: Binding<Int>,
        command: Binding<ComposerCommand?>,
        extraData: [String: Any]
    ) {
        commandsHandler.handleCommand(
            for: text,
            selectedRangeLocation: selectedRangeLocation,
            command: command,
            extraData: extraData
        )
    }
    
    // MARK: - private
    
    private func edit(
        message: ChatMessage,
        completion: @escaping () -> Void
    ) {
        guard let channelId = channelController.channel?.cid else {
            return
        }
        let messageController = chatClient.messageController(
            cid: channelId,
            messageId: message.id
        )
        
        messageController.editMessage(text: text) { [weak self] error in
            if error != nil {
                self?.errorShown = true
            } else {
                completion()
            }
        }
        
        clearInputData()
    }
    
    private func clearInputData() {
        text = ""
        addedAssets = []
        addedFileURLs = []
        addedCustomAttachments = []
        composerCommand = nil
        clearText()
    }
    
    private func checkPickerSelectionState() {
        if (!addedAssets.isEmpty || !addedFileURLs.isEmpty) {
            pickerTypeState = .collapsed
        }
    }
    
    private func checkTypingSuggestions() {
        if composerCommand?.displayInfo?.isInstant == true {
            let typingSuggestion = TypingSuggestion(
                text: text,
                locationRange: NSRange(
                    location: 0,
                    length: selectedRangeLocation
                )
            )
            composerCommand?.typingSuggestion = typingSuggestion
            showTypingSuggestions()
            return
        }
        composerCommand = commandsHandler.canHandleCommand(
            in: text,
            caretLocation: selectedRangeLocation
        )
        
        showTypingSuggestions()
    }
    
    private func showTypingSuggestions() {
        if let composerCommand = composerCommand {
            commandsHandler.showSuggestions(for: composerCommand)
                .sink { _ in
                    log.debug("Finished showing suggestions")
                } receiveValue: { [weak self] suggestionInfo in
                    withAnimation {
                        self?.suggestions[suggestionInfo.key] = suggestionInfo.value
                    }
                }
                .store(in: &cancellables)
        }
    }
    
    private func listenToCooldownUpdates() {
        channelController.channelChangePublisher.sink { [weak self] _ in
            let cooldownDuration = self?.channelController.channel?.cooldownDuration ?? 0
            if self?.cooldownPeriod == cooldownDuration {
                return
            }
            self?.cooldownPeriod = cooldownDuration
            self?.checkChannelCooldown()
        }
        .store(in: &cancellables)
    }
    
    private func checkChannelCooldown() {
        let duration = channelController.channel?.cooldownDuration ?? 0
        if duration > 0 && timer == nil {
            cooldownDuration = duration
            timer = Timer.scheduledTimer(
                withTimeInterval: 1,
                repeats: true,
                block: { [weak self] _ in
                    self?.cooldownDuration -= 1
                    if self?.cooldownDuration == 0 {
                        self?.timer?.invalidate()
                        self?.timer = nil
                    }
                }
            )
            timer?.fire()
        }
    }
    
    private func clearText() {
        // This is needed because of autocompleting text from the keyboard.
        // The update of the text is done in the next cycle, so it overrides
        // the setting of this value to empty string.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.text = ""
        }
    }
    
    private func canAddAttachment(with url: URL) -> Bool {
        if !canAddAdditionalAttachments {
            return false
        }
        
        return checkAttachmentSize(with: url)
    }
    
    private func checkAttachmentSize(with url: URL?) -> Bool {
        guard let url = url else { return true }
        
        _ = url.startAccessingSecurityScopedResource()
        
        do {
            let fileSize = try AttachmentFile(url: url).size
            return fileSize < chatClient.config.maxAttachmentSize
        } catch {
            return false
        }
    }
}
