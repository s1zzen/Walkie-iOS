import XCTest

/// Deterministic local fixtures; no real authentication, account mutations or GPS upload.
final class WalkieSmokeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        addUIInterruptionMonitor(withDescription: "Разрешения iPhone") { alert in
            for label in ["Allow While Using App", "При использовании приложения", "Разрешить при использовании приложения", "Allow", "Разрешить", "OK", "ОК"] {
                if alert.buttons[label].exists { alert.buttons[label].tap(); return true }
            }
            return false
        }
    }

    func testSubmissionDemoCompletedWalk() throws {
        let app = isolatedApp()
        app.launch()
        reachInterests(app)
        chooseInterests(app, ids: ["architecture_history", "parks_nature", "coffee_desserts"])
        finishQuestionnaire(app)
        capture("demo-home", app)
        buildOfflineRoute(app)
        capture("demo-route", app)
        tap(app.buttons["route.save"], app)
        tap(app.buttons["route.place.0"], app)
        capture("demo-place", app)
        tap(app.navigationBars.buttons["Готово"], app)
        tap(app.buttons["route.start"], app)
        handleWalkPermissions(app)
        for index in 0..<5 {
            tap(app.buttons["walk.visitNext"], app)
            if index < 4 { tap(app.buttons["К следующему месту"], app) }
        }
        XCTAssertTrue(app.buttons["Сохранить оценку"].waitForExistence(timeout: 8))
        capture("demo-completed-summary", app)
        tap(app.buttons["Оценить на 5"], app)
        tap(app.buttons["Сохранить оценку"], app)
        if !app.buttons["Не сейчас"].waitForExistence(timeout: 3) {
            tap(app.buttons["tab.3"], app)
            tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Walkie Pro")).firstMatch, app)
        }
        XCTAssertTrue(app.buttons["Не сейчас"].waitForExistence(timeout: 8))
        capture("demo-pro", app)
        tap(app.buttons["Не сейчас"], app)
        tap(app.buttons["tab.1"], app)
        XCTAssertTrue(app.buttons["history.session"].firstMatch.waitForExistence(timeout: 8))
        capture("demo-history", app)
    }

    func testOnboardingRouteLocalWalkHistoryAndRelaunch() throws {
        let app = isolatedApp()
        app.launch()
        reachInterests(app)
        chooseInterests(app, ids: ["architecture_history", "parks_nature", "coffee_desserts"])
        finishQuestionnaire(app)
        capture("03-home", app)
        buildOfflineRoute(app)
        capture("04-route-ready", app)
        tap(app.buttons["route.save"], app)
        XCTAssertTrue(waitValue(app.buttons["route.save"], equals: "Сохранён"))
        tap(app.buttons["route.place.0"], app)
        let favorite = app.buttons["place.favorite"]
        XCTAssertTrue(favorite.waitForExistence(timeout: 5))
        favorite.tap()
        XCTAssertTrue(waitLabel(favorite, contains: "Убрать из избранного"))
        capture("05-place-detail", app)
        tap(app.navigationBars.buttons["Готово"], app)
        tap(app.buttons["route.start"], app)
        handleWalkPermissions(app)
        let visit = app.buttons["walk.visitNext"]
        XCTAssertTrue(visit.waitForExistence(timeout: 12))
        capture("06-local-walk", app)
        tap(visit, app)
        XCTAssertTrue(app.staticTexts["Точка посещена"].waitForExistence(timeout: 5))
        capture("07-visit-confirmed", app)
        tap(app.buttons["К следующему месту"], app)
        tap(app.buttons["walk.menu"], app)
        tap(app.buttons["walk.pause"], app)
        XCTAssertTrue(app.buttons["walk.resume"].waitForExistence(timeout: 5))
        capture("08-walk-paused", app)
        tap(app.buttons["walk.resume"], app)
        XCTAssertTrue(visit.waitForExistence(timeout: 5))
        tap(app.buttons["walk.menu"], app)
        tap(app.buttons["walk.finish"], app)
        tap(app.buttons["Прервать и сохранить"], app)
        XCTAssertTrue(app.staticTexts["Прогулка прервана"].waitForExistence(timeout: 8))
        capture("09-walk-summary", app)
        // Early finish is interruption, not evidence that the route was completed.
        tap(app.buttons["Закрыть"].firstMatch, app)
        if app.buttons["Не сейчас"].waitForExistence(timeout: 3) {
            capture("10-pro-after-walk", app)
            app.buttons["Не сейчас"].tap()
        }
        tap(app.buttons["tab.1"], app)
        let session = app.buttons["history.session"].firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 8))
        capture("11-history", app)
        tap(session, app)
        tap(app.buttons["history.diagnostics"], app)
        let export = app.buttons["history.export"]
        XCTAssertTrue(export.waitForExistence(timeout: 5))
        reveal(export, app)
        XCTAssertTrue(export.isEnabled)
        capture("12-local-research-export", app)
        tap(export, app)
        XCTAssertTrue(app.buttons["Создать экспорт"].waitForExistence(timeout: 3))
        // iOS 26 may render this as a popover without an explicit Cancel row.
        let cancel = app.buttons["Отмена"]
        if cancel.exists && cancel.isHittable { cancel.tap() }
        else {
            let outside = app.otherElements["PopoverDismissRegion"]
            XCTAssertTrue(outside.waitForExistence(timeout: 3))
            outside.tap()
        }
        // No recipient, cloud destination or external application is selected.
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["tab.0"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["onboarding.localDemo"].exists)
        tap(app.buttons["tab.1"], app)
        XCTAssertTrue(app.buttons["history.session"].firstMatch.waitForExistence(timeout: 5))
        tap(app.segmentedControls.buttons["Сохранённые"], app)
        XCTAssertFalse(app.staticTexts["Первый маршрут впереди"].exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "мест")).firstMatch.exists)
        capture("13-relaunch-saved-route", app)
    }

    func testPartialQuestionnaireResumesAndProfileEditSurvivesRelaunch() throws {
        let app = isolatedApp()
        app.launch()
        reachInterests(app)
        let architecture = app.buttons["onboarding.P2.architecture_history"]
        let parks = app.buttons["onboarding.P2.parks_nature"]
        XCTAssertFalse(architecture.isSelected)
        XCTAssertFalse(parks.isSelected)
        chooseInterests(app, ids: ["architecture_history", "parks_nature"])
        XCTAssertFalse(app.buttons["onboarding.nextQuestion"].isEnabled)
        XCTAssertFalse(app.buttons["onboarding.skipQuestion"].exists)
        capture("14-incomplete-mandatory-interests", app)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["onboarding.question.P2"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["onboarding.P2.architecture_history"].isSelected)
        XCTAssertTrue(app.buttons["onboarding.P2.parks_nature"].isSelected)
        chooseInterests(app, ids: ["coffee_desserts"])
        finishQuestionnaire(app)
        tap(app.buttons["tab.3"], app)
        tap(app.buttons["profile.edit"], app)
        XCTAssertTrue(app.staticTexts["onboarding.summary"].waitForExistence(timeout: 5))
        tap(app.buttons["onboarding.editAnswers"], app)
        tap(app.buttons["onboarding.editQuestion.P9"], app)
        XCTAssertTrue(app.staticTexts["onboarding.question.P9"].waitForExistence(timeout: 5))
        tap(app.buttons["onboarding.P9.option_2"], app)
        XCTAssertTrue(app.staticTexts["onboarding.summary"].waitForExistence(timeout: 5))
        capture("15-profile-correction", app)
        tap(app.buttons["onboarding.complete"], app)
        XCTAssertTrue(app.buttons["profile.edit"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        tap(app.buttons["tab.3"], app)
        tap(app.buttons["profile.edit"], app)
        tap(app.buttons["onboarding.editAnswers"], app)
        tap(app.buttons["onboarding.editQuestion.P9"], app)
        XCTAssertTrue(app.buttons["onboarding.P9.option_2"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["onboarding.P9.option_2"].isSelected)
        capture("16-profile-correction-restored", app)
    }

    private func isolatedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["WALKIE_TEST_STORAGE_ID"] = UUID().uuidString
        app.launchEnvironment["WALKIE_OFFLINE_DEMO"] = "1"
        app.launchArguments += ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU"]
        return app
    }

    private func reachInterests(_ app: XCUIApplication) {
        let skip = app.buttons["onboarding.introSkip"]
        XCTAssertTrue(skip.waitForExistence(timeout: 12))
        capture("00-onboarding-figma-hero", app)
        tap(skip, app)
        tap(app.buttons["onboarding.localDemo"], app)
        tap(app.buttons["onboarding.acceptConsent"], app)
        let name = app.textFields["onboarding.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Сергей")
        tap(app.buttons["onboarding.saveName"], app)
        tap(app.buttons["onboarding.startQuestions"], app)
        XCTAssertTrue(app.staticTexts["onboarding.question.P1"].waitForExistence(timeout: 5))
        tap(app.buttons["onboarding.skipQuestion"], app)
        XCTAssertTrue(app.staticTexts["onboarding.question.P2"].waitForExistence(timeout: 5))
        capture("01-profile-interests", app)
    }

    private func chooseInterests(_ app: XCUIApplication, ids: [String]) {
        for id in ids {
            let button = app.buttons["onboarding.P2.\(id)"]
            tap(button, app)
            XCTAssertTrue(waitSelected(button))
        }
    }

    private func finishQuestionnaire(_ app: XCUIApplication) {
        let next = app.buttons["onboarding.nextQuestion"]
        XCTAssertTrue(waitEnabled(next))
        tap(next, app)
        for number in 3...13 {
            XCTAssertTrue(app.staticTexts["onboarding.question.P\(number)"].waitForExistence(timeout: 5))
            tap(app.buttons["onboarding.skipQuestion"], app)
        }
        XCTAssertTrue(app.staticTexts["onboarding.summary"].waitForExistence(timeout: 5))
        capture("02-profile-summary", app)
        tap(app.buttons["onboarding.complete"], app)
        XCTAssertTrue(app.buttons["tab.0"].waitForExistence(timeout: 10))
    }

    private func buildOfflineRoute(_ app: XCUIApplication) {
        tap(app.buttons["planning.generate"], app)
        let originTitle = app.staticTexts["planning.originTitle"]
        XCTAssertTrue(originTitle.waitForExistence(timeout: 5))
        let originalTitle = originTitle.label
        let map = app.maps.firstMatch
        XCTAssertTrue(map.waitForExistence(timeout: 5))
        map.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.3))
            .press(forDuration: 0.15, thenDragTo: map.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.4)))
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", originalTitle), object: originTitle)], timeout: 8) == .completed)
        capture("03a-central-pin-after-drag", app)
        // Return to the supported fixture origin before generation.
        tap(app.buttons["Чистые пруды"], app)
        tap(app.buttons["planning.confirmOrigin"], app)
        tap(app.buttons["planning.confirmFinish"], app)
        tap(app.buttons["planning.confirmBudget"], app)
        tap(app.buttons["planning.context.K1.alone"], app)
        XCTAssertTrue(app.staticTexts["route.title"].waitForExistence(timeout: 15))
    }

    private func tap(_ element: XCUIElement, _ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        // List/LazyVGrid rows beyond the viewport do not enter the accessibility tree until scrolled.
        if !element.waitForExistence(timeout: 2) { reveal(element, app) }
        XCTAssertTrue(element.waitForExistence(timeout: 8), "Элемент не появился: \(element)", file: file, line: line)
        reveal(element, app)
        XCTAssertTrue(waitEnabled(element), "Элемент неактивен: \(element)", file: file, line: line)
        element.tap()
    }

    private func reveal(_ element: XCUIElement, _ app: XCUIApplication) {
        for _ in 0..<8 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable, "Элемент недоступен: \(element)")
    }

    private func waitEnabled(_ element: XCUIElement) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: element)], timeout: 5) == .completed
    }
    private func waitSelected(_ element: XCUIElement) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: element)], timeout: 5) == .completed
    }
    private func waitValue(_ element: XCUIElement, equals value: String) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)], timeout: 5) == .completed
    }
    private func waitLabel(_ element: XCUIElement, contains text: String) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", text), object: element)], timeout: 5) == .completed
    }

    private func allowLocationIfNeeded() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow While Using App", "При использовании приложения", "Разрешить при использовании приложения", "Allow", "Разрешить", "OK", "ОК"] {
            let button = springboard.buttons[label]
            if button.waitForExistence(timeout: 0.5) { button.tap() }
        }
    }

    private func handleWalkPermissions(_ app: XCUIApplication) {
        if app.buttons["permission.allow.location"].waitForExistence(timeout: 3) {
            app.buttons["permission.allow.location"].tap()
            allowLocationIfNeeded()
            if app.buttons["permission.approximate"].waitForExistence(timeout: 1) { app.buttons["permission.approximate"].tap() }
        }
        if app.buttons["permission.skip.motion"].waitForExistence(timeout: 5) {
            capture("permission-motion-optional", app)
            app.buttons["permission.skip.motion"].tap()
        }
        allowLocationIfNeeded()
    }

    private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
