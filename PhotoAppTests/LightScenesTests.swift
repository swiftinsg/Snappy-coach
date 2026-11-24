//
//  LightScenesTests.swift
//  PhotoAppTests
//
//  Light & Exposure on scenes drawn in code. Each scene goes through the app's real measuring code,
//  rules and tips, and, where Apple Intelligence is available, the app's exact model prompt.
//  Drawings have no real faces or objects, so the scene facts Vision would guess (outdoors, the
//  time, the kind of scene) are set by hand after measuring.
//

import CoreGraphics
import Foundation
import FoundationModels
import Testing
@testable import Grp_6pm_Photo_App

/// A scene drawn in code, how it's set up, and what Light & Exposure should make of it.
struct SyntheticScene: CustomTestStringConvertible, Sendable {
    let name: String
    /// Draws in 0...1 coordinates from the top left, like the app's measurements.
    let draw: @Sendable (SceneCanvas) -> Void
    /// The subject's box, as if it had been tapped, so the subject is the same on every run.
    var subject: CGRect? = CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
    var readings = CameraReadings(exposureOffset: 0, exposureSeconds: 1.0 / 120, iso: 100)
    var outdoors = false
    var hour: Int? = 14
    var sceneType: SceneType = .object
    /// Problems that must be found, and ones that mustn't.
    var expected: Set<CoachIssue> = []
    var notExpected: Set<CoachIssue> = []
    /// Whether the scene must find a light source, to prove the scene tests what it means to.
    var needsLightSpot = false

    var testDescription: String { name }
}

/// A grey canvas that draws with the top left as the origin.
struct SceneCanvas {
    let context: CGContext
    let size: CGSize

    func fill(_ rect: CGRect, _ gray: Double) {
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: rect.minX * size.width, y: rect.minY * size.height,
                            width: rect.width * size.width, height: rect.height * size.height))
    }

    func ellipse(_ rect: CGRect, _ gray: Double) {
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fillEllipse(in: CGRect(x: rect.minX * size.width, y: rect.minY * size.height,
                                       width: rect.width * size.width, height: rect.height * size.height))
    }

    func background(_ gray: Double) {
        fill(CGRect(x: 0, y: 0, width: 1, height: 1), gray)
    }

    /// Draws a scene into an RGB image, as the camera would hand it over.
    static func image(_ draw: (SceneCanvas) -> Void) -> CGImage? {
        let width = 768, height = 1024
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        // Flip, so drawing uses the top-left origin the measurements use.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        draw(SceneCanvas(context: context, size: CGSize(width: width, height: height)))
        return context.makeImage()
    }
}

extension SyntheticScene {
    /// Bright daylight: 1/4000 s at ISO 50, about EV 14.6.
    static let sunshine = CameraReadings(exposureOffset: 0, exposureSeconds: 1.0 / 4000, iso: 50)
    /// Rain: 1/250 s at ISO 64, about EV 10.
    static let rain = CameraReadings(exposureOffset: 0, exposureSeconds: 1.0 / 250, iso: 64)
    /// A dark room or street: 1/15 s at ISO 3200.
    static let dark = CameraReadings(exposureOffset: 0, exposureSeconds: 1.0 / 15, iso: 3200)

    static let all: [SyntheticScene] = [
        SyntheticScene(
            name: "01 even room",
            draw: { c in
                c.background(0.5)
                c.fill(CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4), 0.55)
            },
            notExpected: [.underexposed, .overexposed, .tooDark, .backlitSubject, .highlightsClipped,
                          .harshContrast, .subjectInShadow, .subjectTooBright, .sunInFrame]
        ),
        SyntheticScene(
            name: "02 white sky behind dark subject",
            draw: { c in
                c.background(0.97)
                c.fill(CGRect(x: 0.3, y: 0.35, width: 0.4, height: 0.5), 0.15)
            },
            subject: CGRect(x: 0.3, y: 0.35, width: 0.4, height: 0.5),
            readings: sunshine, outdoors: true,
            expected: [.backlitSubject], notExpected: [.subjectInShadow]
        ),
        SyntheticScene(
            name: "03 sun in a blue sky",
            draw: { c in
                c.background(0.6)
                c.fill(CGRect(x: 0.08, y: 0.06, width: 0.12, height: 0.09), 1)
            },
            readings: sunshine, outdoors: true,
            expected: [.sunInFrame], needsLightSpot: true
        ),
        SyntheticScene(
            name: "04 nearly black",
            draw: { c in c.background(0.08) },
            readings: dark,
            expected: [.tooDark]
        ),
        SyntheticScene(
            name: "05 dim room with one lamp",
            draw: { c in
                c.background(0.4)
                c.fill(CGRect(x: 0.65, y: 0.1, width: 0.2, height: 0.22), 1)
            },
            subject: CGRect(x: 0.2, y: 0.45, width: 0.35, height: 0.4),
            notExpected: [.highlightsClipped, .harshContrast, .sunInFrame], needsLightSpot: true
        ),
        SyntheticScene(
            name: "06 subject in shadow, sunny around",
            draw: { c in
                c.background(0.6)
                c.fill(CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.45), 0.15)
            },
            subject: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.45),
            readings: sunshine, outdoors: true,
            expected: [.subjectInShadow], notExpected: [.backlitSubject]
        ),
        SyntheticScene(
            name: "07 spotlit on a dark stage",
            draw: { c in
                c.background(0.12)
                c.fill(CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4), 0.93)
            },
            expected: [.subjectTooBright], notExpected: [.overexposed]
        ),
        SyntheticScene(
            name: "08 harsh: white band and deep shadow",
            draw: { c in
                c.background(0.5)
                c.fill(CGRect(x: 0, y: 0, width: 1, height: 0.08), 1)
                c.fill(CGRect(x: 0, y: 0.82, width: 1, height: 0.18), 0)
            },
            readings: {
                // Exposure already pulled down a stop, so the white is the light, not the setting.
                var r = sunshine
                r.exposureBias = -1
                return r
            }(),
            outdoors: true,
            expected: [.harshContrast]
        ),
        SyntheticScene(
            name: "09 white sky, nobody",
            draw: { c in
                c.background(0.45)
                c.fill(CGRect(x: 0, y: 0, width: 1, height: 0.3), 1)
            },
            subject: CGRect(x: 0.3, y: 0.5, width: 0.4, height: 0.4),
            readings: sunshine, outdoors: true,
            expected: [.highlightsClipped], notExpected: [.backlitSubject]
        ),
        SyntheticScene(
            name: "10 flat grey street in the rain",
            draw: { c in
                c.background(0.45)
                c.fill(CGRect(x: 0, y: 0.6, width: 1, height: 0.4), 0.38)
                c.fill(CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.4), 0.5)
            },
            readings: rain, outdoors: true
        ),
        SyntheticScene(
            name: "11 night street with a lamp",
            draw: { c in
                c.background(0.2)
                c.fill(CGRect(x: 0.45, y: 0.08, width: 0.1, height: 0.08), 1)
            },
            readings: CameraReadings(exposureOffset: 0, exposureSeconds: 1.0 / 15, iso: 1600),
            outdoors: true, hour: 22,
            notExpected: [.sunInFrame], needsLightSpot: true
        ),
        SyntheticScene(
            name: "12 dappled light on the subject",
            draw: { c in
                c.background(0.5)
                c.fill(CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4), 0.45)
                for row in 0..<4 {
                    for column in 0..<4 where (row + column).isMultiple(of: 2) {
                        c.ellipse(CGRect(x: 0.32 + Double(column) * 0.09, y: 0.32 + Double(row) * 0.09,
                                         width: 0.07, height: 0.07), 0.9)
                    }
                }
            },
            readings: sunshine, outdoors: true
        ),
        SyntheticScene(
            name: "13 oval lit from one side",
            draw: { c in
                c.background(0.45)
                c.ellipse(CGRect(x: 0.3, y: 0.25, width: 0.4, height: 0.5), 0.85)
                c.fill(CGRect(x: 0.5, y: 0.25, width: 0.2, height: 0.5), 0.45)
                c.context.saveGState()
                c.context.clip(to: CGRect(x: 0.5 * c.size.width, y: 0, width: c.size.width, height: c.size.height))
                c.ellipse(CGRect(x: 0.3, y: 0.25, width: 0.4, height: 0.5), 0.1)
                c.context.restoreGState()
            },
            subject: CGRect(x: 0.3, y: 0.25, width: 0.4, height: 0.5)
        ),
        SyntheticScene(
            name: "14 harsh city view",
            draw: { c in
                c.background(0.5)
                c.fill(CGRect(x: 0, y: 0, width: 1, height: 0.08), 1)
                c.fill(CGRect(x: 0, y: 0.82, width: 1, height: 0.18), 0)
            },
            readings: {
                var r = sunshine
                r.exposureBias = -1
                return r
            }(),
            outdoors: true, sceneType: .city,
            expected: [.harshContrast]
        ),
    ]
}

@MainActor
struct LightScenesTests {
    /// Draws and measures a scene with the app's code, then sets the facts drawings can't show.
    static func measure(_ scene: SyntheticScene) async -> (image: CGImage, analysis: SceneAnalysis)? {
        guard let image = SceneCanvas.image(scene.draw),
              var analysis = await SceneAnalysis.analyze(image, readings: scene.readings, selectedSubject: scene.subject)
        else { return nil }
        analysis.scene = scene.sceneType
        analysis.backdrop = nil
        analysis.isOutdoors = scene.outdoors
        analysis.hour = scene.hour
        analysis.faces = []
        analysis.people = []
        analysis.otherThings = []
        return (image, analysis)
    }

    @Test(arguments: SyntheticScene.all)
    func measuredProblemsMatchEachScene(_ scene: SyntheticScene) async throws {
        let measured = try #require(await Self.measure(scene))
        let a = measured.analysis
        let issues = Set(CoachRules.issues(for: .light, in: a))
        for issue in scene.expected {
            #expect(issues.contains(issue), "\(scene.name): expected \(issue), found \(issues.map(\.rawValue).sorted())")
        }
        for issue in scene.notExpected {
            #expect(!issues.contains(issue), "\(scene.name): didn't expect \(issue)")
        }
        if scene.needsLightSpot {
            #expect(a.lightSpot != nil, "\(scene.name): no light source found, so the scene doesn't test what it means to")
        }
    }

    @Test func rainAndCityScenesGetTheRightTips() async throws {
        // Rain: whatever the model says, it can't be hard shadows, patches of sun or glare.
        let rain = try #require(await Self.measure(SyntheticScene.all[9])).analysis
        #expect(rain.isSoftDaylight)
        for issue: CoachIssue in [.hardShadowsOnSubject, .patchyLight, .sunGlare] {
            #expect(!CoachRules.believes(issue, detail: nil, analysis: rain))
        }
        // A harsh city view can't move: wait for softer light, and shoot RAW meanwhile.
        let city = try #require(await Self.measure(SyntheticScene.all[13])).analysis
        let advice = CoachIssue.harshContrast.advice(for: .light, analysis: city)
        #expect(advice.mover == .wait)
        #expect(advice.quickFix == .raw)
    }

    /// Runs every scene through the measurements, the model and the tip, and prints a table.
    /// Model answers on drawings aren't a fair pass or fail, so this reports rather than checks.
    @Test(.enabled(if: SystemLanguageModel.default.isAvailable))
    func modelReport() async throws {
        let coach = PhotoCoach()
        var rows = ["scene | measured | app asks model? | model says | believed? | tip shown | who moves | one-tap"]
        for scene in SyntheticScene.all {
            let measured = try #require(await Self.measure(scene))
            let a = measured.analysis
            var issues = CoachRules.issues(for: .light, in: a)
            let blocked = issues.contains { $0.blocksModel(in: .light) }
            let handled = [
                CoachRules.handledNote(issues: issues, keepsPlacement: false, placement: CompositionGuide.guidePlacement(for: [])),
                CoachRules.lightKeepNote(keepsFraming: false),
            ].compactMap(\.self).joined(separator: " ")
            let judgement = await coach.judge(measured.image, topic: .light, styles: [], analysis: a, handled: handled)
            let said = judgement.map { "\($0.issue.rawValue) (\($0.region.rawValue)) \"\($0.strength)\"" } ?? "no answer"
            var believed = "-"
            if let judgement, let issue = judgement.issue.coachIssue {
                let accepted = CoachRules.allows(judgement.issue, for: .light) && CoachRules.believes(issue, detail: nil, analysis: a)
                believed = accepted ? "yes" : "no"
                // As in the app: the model's problem leads, but only when the app would have asked it.
                if accepted, !blocked {
                    issues.removeAll { $0 == issue }
                    issues.insert(issue, at: 0)
                }
            }
            let top = issues.first
            let advice = top?.advice(for: .light, analysis: a)
            rows.append([
                scene.name,
                issues.isEmpty ? "none" : CoachRules.issues(for: .light, in: a).map(\.rawValue).joined(separator: ", "),
                blocked ? "no (blocked)" : "yes",
                said,
                believed,
                advice?.action ?? "Looks good",
                advice?.mover?.label ?? "-",
                advice?.quickFix?.title ?? "-",
            ].joined(separator: " | "))
        }
        print("\n=== Light & Exposure scene report ===\n" + rows.joined(separator: "\n") + "\n=== end ===\n")
    }
}
