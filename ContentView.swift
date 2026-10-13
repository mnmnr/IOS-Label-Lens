
import SwiftUI
import PhotosUI
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

// MARK: - Ingredient Model

struct IngredientInfo: Codable, Identifiable {
    let name: String
    let aliases: [String]
    let category: String
    let purpose: String
    let explanation: String
    let note: String
    let source: String

    var id: String { name }
}

// MARK: - Ingredient Database

struct IngredientDatabase {
    static func load() -> [IngredientInfo] {
        guard
            let url = Bundle.main.url(
                forResource: "ingredients",
                withExtension: "json"
            ),
            let data = try? Data(contentsOf: url),
            let ingredients = try? JSONDecoder().decode(
                [IngredientInfo].self,
                from: data
            )
        else {
            return []
        }

        return ingredients
    }
}

// MARK: - Ingredient Parser

struct IngredientParser {

    static func normalize(_ text: String) -> String {
        text.lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    static func extractIngredients(from text: String) -> [String] {
        let lines = text.components(separatedBy: .newlines)

        guard let startIndex = lines.firstIndex(where: {
            $0.localizedCaseInsensitiveContains("ingredients")
        }) else {
            // Do not guess which words are ingredients.
            return []
        }

        var relevantLines = Array(lines[startIndex...])

        // Remove the heading from the first line.
        if !relevantLines.isEmpty,
           let range = relevantLines[0].range(
                of: "ingredients",
                options: .caseInsensitive
           ) {
            relevantLines[0].removeSubrange(range)
        }

        // Stop at common unrelated label sections.
        let stopWords = [
            "directions", "how to use", "warning",
            "caution", "distributed by", "made in"
        ]

        var collectedLines: [String] = []

        for line in relevantLines {
            let lower = line.lowercased()

            if stopWords.contains(where: {
                lower.contains($0)
            }) {
                break
            }

            collectedLines.append(line)
        }

        let combined = collectedLines.joined(separator: " ")
            .replacingOccurrences(of: ":", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Cosmetic ingredient lists are commonly comma-separated.
        return combined
            .components(separatedBy: CharacterSet(charactersIn: ",;"))
            .map {
                $0.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            }
            .map {
                $0.trimmingCharacters(
                    in: CharacterSet(charactersIn: ".•- ")
                )
            }
            .filter { !$0.isEmpty && $0.count < 100 }
    }
}

// MARK: - Main Screen

struct ContentView: View {

    @State private var selectedPhoto: PhotosPickerItem?
    @State private var productImage: UIImage?

    @State private var recognizedText = ""
    @State private var ingredientNames: [String] = []
    @State private var database: [IngredientInfo] = []

    @State private var isProcessing = false
    @State private var statusMessage = "Choose a product label to begin."

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    introduction

                    photoPickerSection

                    if let image = productImage {
                        imageSection(image)
                    }

                    if !recognizedText.isEmpty {
                        textEditorSection
                    }

                    if !ingredientNames.isEmpty {
                        resultsSection
                    }

                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle("LabelLens")
            .task {
                database = IngredientDatabase.load()

                if database.isEmpty {
                    statusMessage =
                    "Ingredient data could not be loaded. Check that ingredients.json is included in the app target."
                }
            }
            .onChange(of: selectedPhoto) { _, newPhoto in
                Task {
                    await loadPhoto(newPhoto)
                }
            }
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Understand what's in your products.")
                .font(.title2.bold())

            Text(
                "Scan a cosmetic ingredient label, review the extracted text, and explore ingredient explanations."
            )
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var photoPickerSection: some View {
        PhotosPicker(
            selection: $selectedPhoto,
            matching: .images
        ) {
            Label(
                "Choose Label Photo",
                systemImage: "photo.on.rectangle"
            )
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
    }

    private func imageSection(_ image: UIImage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Selected Image")
                .font(.headline)

            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 300)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            HStack {
                Button("Recognize Text") {
                    recognizeText(in: image)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isProcessing)

                Button("Enhance Image") {
                    let enhanced = enhance(image)
                    productImage = enhanced
                    recognizeText(in: enhanced)
                }
                .buttonStyle(.bordered)
                .disabled(isProcessing)
            }
        }
    }

    private var textEditorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Review Extracted Text")
                .font(.headline)

            Text(
                "Correct OCR mistakes before analyzing the ingredients."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)

            TextEditor(text: $recognizedText)
                .frame(minHeight: 160)
                .padding(6)
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(.gray.opacity(0.35))
                }

            Button("Analyze Ingredients") {
                ingredientNames =
                    IngredientParser.extractIngredients(
                        from: recognizedText
                    )

                if ingredientNames.isEmpty {
                    statusMessage =
                    "No ingredient list detected. Check the text for an Ingredients heading or correct it manually."
                } else {
                    statusMessage =
                    "\(ingredientNames.count) ingredient entries extracted."
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ingredient Results")
                .font(.title3.bold())

            ForEach(
                Array(ingredientNames.enumerated()),
                id: \.offset
            ) { _, ingredientName in

                NavigationLink {
                    IngredientDetailView(
                        ingredientName: ingredientName,
                        database: database
                    )
                } label: {
                    ingredientRow(ingredientName)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func ingredientRow(
        _ ingredientName: String
    ) -> some View {
        let match = findIngredient(ingredientName)

        return HStack(spacing: 12) {
            Image(
                systemName: match == nil
                    ? "questionmark.circle"
                    : "checkmark.circle"
            )
            .font(.title2)
            .foregroundStyle(
                match == nil ? .orange : .green
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(ingredientName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)

                Text(
                    match?.purpose ?? "Not found in the database"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func findIngredient(
        _ text: String
    ) -> IngredientInfo? {
        let cleaned = IngredientParser.normalize(text)

        return database.first { item in
            let names = [item.name] + item.aliases

            return names.contains { name in
                let normalizedName =
                    IngredientParser.normalize(name)

                return cleaned == normalizedName ||
                    cleaned.contains(normalizedName)
            }
        }
    }

    // MARK: - Photo Loading

    @MainActor
    private func loadPhoto(
        _ item: PhotosPickerItem?
    ) async {
        guard let item else { return }

        do {
            guard let data = try await item.loadTransferable(
                type: Data.self
            ),
            let image = UIImage(data: data) else {
                statusMessage = "Could not load that image."
                return
            }

            productImage = image
            recognizedText = ""
            ingredientNames = []
            statusMessage =
                "Image loaded. Tap Recognize Text to continue."

        } catch {
            statusMessage =
                "Photo loading failed: \(error.localizedDescription)"
        }
    }

    // MARK: - OCR

    private func recognizeText(in image: UIImage) {
        guard let cgImage = image.cgImage else {
            statusMessage = "Could not process this image."
            return
        }

        isProcessing = true
        statusMessage = "Recognizing label text..."

        DispatchQueue.global(qos: .userInitiated).async {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["en-US"]

            let handler = VNImageRequestHandler(
                cgImage: cgImage,
                options: [:]
            )

            do {
                try handler.perform([request])

                let lines = (request.results ?? [])
                    .compactMap {
                        $0.topCandidates(1).first?.string
                    }

                let result = lines.joined(separator: "\n")

                DispatchQueue.main.async {
                    recognizedText = result
                    ingredientNames = []
                    isProcessing = false

                    statusMessage = result.isEmpty
                        ? "No text detected. Try a clearer image."
                        : "Text recognized. Review it before analysis."
                }

            } catch {
                DispatchQueue.main.async {
                    isProcessing = false
                    statusMessage =
                        "Text recognition failed. Try another photo."
                }
            }
        }
    }

    // MARK: - Basic Image Enhancement

    private func enhance(_ image: UIImage) -> UIImage {
        guard let input = CIImage(image: image) else {
            return image
        }

        let filter = CIFilter.colorControls()
        filter.inputImage = input
        filter.contrast = 1.25
        filter.brightness = 0.03
        filter.saturation = 1.0

        let context = CIContext()

        guard let output = filter.outputImage,
              let cgImage = context.createCGImage(
                output,
                from: output.extent
              ) else {
            return image
        }

        return UIImage(
            cgImage: cgImage,
            scale: image.scale,
            orientation: image.imageOrientation
        )
    }
}

// MARK: - Ingredient Detail Screen

struct IngredientDetailView: View {

    let ingredientName: String
    let database: [IngredientInfo]

    private var ingredient: IngredientInfo? {
        let cleaned = IngredientParser.normalize(
            ingredientName
        )

        return database.first { item in
            ([item.name] + item.aliases).contains { name in
                let normalized =
                    IngredientParser.normalize(name)

                return cleaned == normalized ||
                    cleaned.contains(normalized)
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {

                if let ingredient {
                    Text(ingredient.name)
                        .font(.largeTitle.bold())

                    detailBlock(
                        title: "Category",
                        content: ingredient.category
                    )

                    detailBlock(
                        title: "What it does",
                        content: ingredient.purpose
                    )

                    detailBlock(
                        title: "In simple terms",
                        content: ingredient.explanation
                    )

                    detailBlock(
                        title: "Important context",
                        content: ingredient.note
                    )

                    detailBlock(
                        title: "Reference",
                        content: ingredient.source
                    )

                } else {
                    Text(ingredientName)
                        .font(.largeTitle.bold())

                    Label(
                        "Ingredient not recognized",
                        systemImage: "questionmark.circle"
                    )
                    .font(.headline)

                    Text(
                        "This name was not matched to an entry in the local database. Check the spelling or compare it with a trusted reference."
                    )

                    Text(
                        "An unknown ingredient is not necessarily harmful."
                    )
                    .foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(
                maxWidth: .infinity,
                alignment: .leading
            )
        }
        .navigationTitle("Ingredient Details")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func detailBlock(
        title: String,
        content: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)

            Text(content)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    ContentView()
}
