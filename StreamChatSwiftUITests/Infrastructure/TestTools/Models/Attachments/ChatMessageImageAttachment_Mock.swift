//
// Copyright © 2022 Stream.io Inc. All rights reserved.
//

import Foundation
@testable import StreamChat

extension ChatMessageImageAttachment {
    /// Creates a new `ChatMessageImageAttachment` object from the provided data.
    public static func mock(
        id: AttachmentId,
        imageURL: URL = .localYodaImage,
        title: String = URL.localYodaImage.lastPathComponent,
        localState: LocalAttachmentState? = nil,
        extraData: [String: RawJSON]? = nil
    ) -> Self {
        .init(
            id: id,
            type: .image,
            payload: .init(
                title: title,
                imageRemoteURL: imageURL,
                imagePreviewRemoteURL: imageURL,
                extraData: extraData
            ),
            uploadingState: localState.map {
                .init(
                    localFileURL: imageURL,
                    state: $0,
                    file: try! AttachmentFile(url: imageURL)
                )
            }
        )
    }
}
