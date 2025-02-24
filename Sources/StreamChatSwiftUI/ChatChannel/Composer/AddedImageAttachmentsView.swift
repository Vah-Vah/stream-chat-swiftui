//
// Copyright © 2022 Stream.io Inc. All rights reserved.
//

import SwiftUI

/// View for an added image displayed in the composer input.
public struct AddedImageAttachmentsView: View {
    @Injected(\.fonts) private var fonts
    @Injected(\.colors) private var colors
    
    public var images: [AddedAsset]
    public var onDiscardAttachment: (String) -> Void
    
    private var imageSize: CGFloat = 100
    
    public init(
        images: [AddedAsset],
        onDiscardAttachment: @escaping (String) -> Void
    ) {
        self.images = images
        self.onDiscardAttachment = onDiscardAttachment
    }
    
    public var body: some View {
        ScrollView(.horizontal) {
            HStack {
                ForEach(images) { attachment in
                    Image(uiImage: attachment.image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: imageSize, height: imageSize)
                        .clipped()
                        .cornerRadius(12)
                        .overlay(
                            ZStack {
                                DiscardAttachmentButton(
                                    attachmentIdentifier: attachment.id,
                                    onDiscard: onDiscardAttachment
                                )
                                
                                if attachment.type == .video {
                                    VideoIndicatorView()
                                    
                                    if let duration = attachment.extraData["duration"] as? String {
                                        VideoDurationIndicatorView(duration: duration)
                                    }
                                }
                            }
                        )
                }
            }
        }
        .frame(height: imageSize)
    }
}
