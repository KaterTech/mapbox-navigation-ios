import UIKit
import Mapbox
import MapboxDirections
import MapboxCoreNavigation
import MapboxMobileEvents
import Turf
import AVFoundation

class ArrowFillPolyline: MGLPolylineFeature {}
class ArrowStrokePolyline: ArrowFillPolyline {}

extension RouteMapViewController: NavigationComponent {
        
    func navigationService(_ service: NavigationService, didUpdate progress: RouteProgress, with location: CLLocation, rawLocation: CLLocation) {
        
        navigationComponents.forEach { $0.navigationService?(service, didUpdate: progress, with: location, rawLocation: rawLocation) }
        
        let route = progress.route
        let legIndex = progress.legIndex
        let stepIndex = progress.currentLegProgress.stepIndex
        
        instructionsBannerView.updateDistance(for: progress.currentLegProgress.currentStepProgress)
        
        mapView.updatePreferredFrameRate(for: progress)
        if currentLegIndexMapped != legIndex {
            mapView.showWaypoints(route, legIndex: legIndex)
            mapView.showRoutes([route], legIndex: legIndex)
            
            currentLegIndexMapped = legIndex
        }
        
        if currentStepIndexMapped != stepIndex {
            updateMapOverlays(for: progress)
            currentStepIndexMapped = stepIndex
        }
        
        if annotatesSpokenInstructions {
            mapView.showVoiceInstructionsOnMap(route: route)
        }
    }
    
    @objc public func navigationService(_ service: NavigationService, didPassSpokenInstructionPoint instruction: SpokenInstruction, routeProgress: RouteProgress) {
        updateCameraAltitude(for: routeProgress)
    }
    
    @objc public func navigationService(_ service: NavigationService, didPassVisualInstructionPoint instruction: VisualInstructionBanner, routeProgress: RouteProgress) {
        guard currentPreviewInstructionBannerStepIndex == nil else { return }
        navigationComponents.forEach {$0.navigationService?(service, didPassVisualInstructionPoint: instruction, routeProgress: routeProgress)}
    }
    
    func navigationService(_ service: NavigationService, willBeginSimulating progress: RouteProgress, becauseOf reason: SimulationIntent) {
        if service.simulationMode == .always {
            showSimulationStatus(speed: 1)
        }
    }
    
    func navigationService(_ service: NavigationService, willEndSimulating progress: RouteProgress, becauseOf reason: SimulationIntent) {
        if service.simulationMode == .always {
            hideStatus()
        }
    }
    
    func navigationService(_ service: NavigationService, willRerouteFrom location: CLLocation) {
        let title = NSLocalizedString("REROUTING", bundle: .mapboxNavigation, value: "Rerouting…", comment: "Indicates that rerouting is in progress")
        lanesView.hide()
        showStatus(title: title, withSpinner: true, for: .infinity)
    }
    
    func navigationService(_ service: NavigationService, didRerouteAlong route: Route, at location: CLLocation?, proactive: Bool) {
        navigationComponents.forEach { $0.navigationService?(service, didRerouteAlong: route, at: location, proactive: proactive) }
        currentStepIndexMapped = 0
        let route = router.route
        let stepIndex = router.routeProgress.currentLegProgress.stepIndex
        let legIndex = router.routeProgress.legIndex
        
        instructionsBannerView.updateDistance(for: router.routeProgress.currentLegProgress.currentStepProgress)
        
        mapView.addArrow(route: route, legIndex: legIndex, stepIndex: stepIndex + 1)
        mapView.showRoutes([route], legIndex: legIndex)
        mapView.showWaypoints(route)
        
        if annotatesSpokenInstructions {
            mapView.showVoiceInstructionsOnMap(route: route)
        }
        
        if isInOverviewMode {
            if let coordinates = route.coordinates, let userLocation = router.location?.coordinate {
                mapView.contentInset = contentInset(forOverviewing: true)
                mapView.setOverheadCameraView(from: userLocation, along: coordinates, for: contentInset(forOverviewing: true))
            }
        } else {
            mapView.tracksUserCourse = true
            navigationView.wayNameView.isHidden = true
        }
        
        stepsViewController?.dismiss {
            self.removePreviewInstructions()
            self.stepsViewController = nil
            self.navigationView.instructionsBannerView.stepListIndicatorView.isHidden = false
        }
        
        if let locationManager = navService.locationManager as? SimulatedLocationManager {
            showSimulationStatus(speed: Int(locationManager.speedMultiplier))
        } else {
            hideStatus(after: 2)
        }
        
        if proactive {
            let title = NSLocalizedString("FASTER_ROUTE_FOUND", bundle: .mapboxNavigation, value: "Faster Route Found", comment: "Indicates a faster route was found")
            showStatus(title: title, withSpinner: true, for: 3)
        }
    }
    
    func navigationService(_ service: NavigationService, didFailToRerouteWith error: Error) {
        hideStatus()
    }
}


class RouteMapViewController: UIViewController {

    var navigationView: NavigationView { return view as! NavigationView }
    var mapView: NavigationMapView { return navigationView.mapView }
    var statusView: StatusView { return navigationView.statusView }
    var reportButton: FloatingButton { return navigationView.reportButton }
    var lanesView: LanesView { return navigationView.lanesView }
    var nextBannerView: NextBannerView { return navigationView.nextBannerView }
    var instructionsBannerView: InstructionsBannerView { return navigationView.instructionsBannerView }
    var instructionsBannerContentView: InstructionsBannerContentView { return navigationView.instructionsBannerContentView }
    var bottomBannerContainerView: BottomBannerContainerView { return navigationView.bottomBannerContainerView }

    var navigationComponents: [NavigationComponent] {
        return [instructionsBannerView, nextBannerView, lanesView]//, bottomBannerView]
    }
    
    lazy var endOfRouteViewController: EndOfRouteViewController = {
        let storyboard = UIStoryboard(name: "Navigation", bundle: .mapboxNavigation)
        let viewController = storyboard.instantiateViewController(withIdentifier: "EndOfRouteViewController") as! EndOfRouteViewController
        return viewController
    }()

    private struct Actions {
        static let overview: Selector = #selector(RouteMapViewController.toggleOverview(_:))
        static let mute: Selector = #selector(RouteMapViewController.toggleMute(_:))
        static let feedback: Selector = #selector(RouteMapViewController.feedback(_:))
        static let recenter: Selector = #selector(RouteMapViewController.recenter(_:))
    }

    var route: Route { return navService.router.route }
    var currentPreviewInstructionBannerStepIndex: Int?
    var previewInstructionsView: StepInstructionsView?
    var lastTimeUserRerouted: Date?
    var stepsViewController: StepsViewController?
    private lazy var geocoder: CLGeocoder = CLGeocoder()
    var destination: Waypoint?
    var isUsedInConjunctionWithCarPlayWindow = false {
        didSet {
            if isUsedInConjunctionWithCarPlayWindow {
                displayPreviewInstructions()
            } else {
                stepsViewController?.dismiss()
            }
        }
    }

    var showsEndOfRoute: Bool = true

    var pendingCamera: MGLMapCamera? {
        guard let parent = parent as? NavigationViewController else {
            return nil
        }
        return parent.pendingCamera
    }

    var tiltedCamera: MGLMapCamera {
        get {
            let camera = mapView.camera
            camera.altitude = 1000
            camera.pitch = 45
            return camera
        }
    }
    
    var styleObservation: NSKeyValueObservation?
    
    weak var delegate: RouteMapViewControllerDelegate?
    var navService: NavigationService! {
        didSet {
            statusView.isEnabled = navService.locationManager is SimulatedLocationManager
            guard let destination = route.legs.last?.destination else { return }
            populateName(for: destination, populated: { self.destination = $0 })
        }
    }
    var router: Router { return navService.router }
    let distanceFormatter = DistanceFormatter(approximate: true)
    var arrowCurrentStep: RouteStep?
    var isInOverviewMode = false {
        didSet {
            if isInOverviewMode {
                navigationView.overviewButton.isHidden = true
                navigationView.resumeButton.isHidden = false
                navigationView.wayNameView.isHidden = true
                mapView.logoView.isHidden = true
            } else {
                navigationView.overviewButton.isHidden = false
                navigationView.resumeButton.isHidden = true
                mapView.logoView.isHidden = false
            }
        }
    }
    var currentLegIndexMapped = 0
    var currentStepIndexMapped = 0

    /**
     A Boolean value that determines whether the map annotates the locations at which instructions are spoken for debugging purposes.
     */
    var annotatesSpokenInstructions = false

    var overheadInsets: UIEdgeInsets {
        return UIEdgeInsets(top: navigationView.instructionsBannerView.bounds.height, left: 20, bottom: bottomBannerContainerView.bounds.height, right: 20)
    }

    typealias LabelRoadNameCompletionHandler = (_ defaultRaodNameAssigned: Bool) -> Void

    var labelRoadNameCompletionHandler: (LabelRoadNameCompletionHandler)?

    convenience init(navigationService: NavigationService, delegate: RouteMapViewControllerDelegate? = nil, bottomBanner: ContainerViewController) {
        
        self.init()
        self.navService = navigationService
        self.delegate = delegate
        automaticallyAdjustsScrollViewInsets = false
        
        embed(bottomBanner, in: navigationView.bottomBannerContainerView) { (parent, banner) -> [NSLayoutConstraint] in
            banner.view.translatesAutoresizingMaskIntoConstraints = false
            return banner.view.constraintsForPinning(to: self.navigationView.bottomBannerContainerView)
        }
    }


    override func loadView() {
        view = NavigationView(delegate: self)
        view.frame = parent?.view.bounds ?? UIScreen.main.bounds
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        
        let mapView = self.mapView
        mapView.contentInset = contentInset(forOverviewing: false)
        view.layoutIfNeeded()

        mapView.tracksUserCourse = true
        instructionsBannerView.swipeable = true
        
        styleObservation = mapView.observe(\.style, options: .new) { [weak self] (mapView, change) in
            guard change.newValue != nil else {
                return
            }
            self?.showRouteIfNeeded()
            mapView.localizeLabels()
        }
        
        distanceFormatter.numberFormatter.locale = .nationalizedCurrent

        makeGestureRecognizersResetFrameRate()
        navigationView.overviewButton.addTarget(self, action: Actions.overview, for: .touchUpInside)
        navigationView.muteButton.addTarget(self, action: Actions.mute, for: .touchUpInside)
        navigationView.reportButton.addTarget(self, action: Actions.feedback, for: .touchUpInside)
        navigationView.resumeButton.addTarget(self, action: Actions.recenter, for: .touchUpInside)
        statusView.addTarget(self, action: #selector(didChangeSpeed(_:)), for: .valueChanged)
        resumeNotifications()
        notifyUserAboutLowVolume()
        updateInstructionBanners(visualInstructionBanner: router.routeProgress.currentLegProgress.currentStepProgress.currentVisualInstruction)
    }

    deinit {
        suspendNotifications()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        navigationView.muteButton.isSelected = NavigationSettings.shared.voiceMuted
        mapView.compassView.isHidden = true

        mapView.tracksUserCourse = true

        if let camera = pendingCamera {
            mapView.camera = camera
        } else if let location = router.location, location.course > 0 {
            mapView.updateCourseTracking(location: location, animated: false)
        } else if let coordinates = router.routeProgress.currentLegProgress.currentStep.coordinates, let firstCoordinate = coordinates.first, coordinates.count > 1 {
            let secondCoordinate = coordinates[1]
            let course = firstCoordinate.direction(to: secondCoordinate)
            let newLocation = CLLocation(coordinate: router.location?.coordinate ?? firstCoordinate, altitude: 0, horizontalAccuracy: 0, verticalAccuracy: 0, course: course, speed: 0, timestamp: Date())
            mapView.updateCourseTracking(location: newLocation, animated: false)
        } else {
            mapView.setCamera(tiltedCamera, animated: false)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        annotatesSpokenInstructions = delegate?.mapViewControllerShouldAnnotateSpokenInstructions(self) ?? false
        showRouteIfNeeded()
        currentLegIndexMapped = router.routeProgress.legIndex
        currentStepIndexMapped = router.routeProgress.currentLegProgress.stepIndex
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        styleObservation = nil
    }

    func resumeNotifications() {
        NotificationCenter.default.addObserver(self, selector: #selector(applicationWillEnterForeground(notification:)), name: UIApplication.willEnterForegroundNotification, object: nil)
        subscribeToKeyboardNotifications()
    }

    func suspendNotifications() {
        NotificationCenter.default.removeObserver(self, name: UIApplication.willEnterForegroundNotification, object: nil)
        unsubscribeFromKeyboardNotifications()
    }

    func embed(_ child: UIViewController, in container: UIView, constrainedBy constraints: ((RouteMapViewController, UIViewController) -> [NSLayoutConstraint])?) {
        child.willMove(toParent: self)
        addChild(child)
        container.addSubview(child.view)
        if let childConstraints: [NSLayoutConstraint] = constraints?(self, child) {
            view.addConstraints(childConstraints)
        }
        child.didMove(toParent: self)
    }
    
    @objc func recenter(_ sender: AnyObject) {
        mapView.tracksUserCourse = true
        mapView.enableFrameByFrameCourseViewTracking(for: 3)
        isInOverviewMode = false

        updateCameraAltitude(for: router.routeProgress)
        
        mapView.addArrow(route: router.route,
                         legIndex: router.routeProgress.legIndex,
                         stepIndex: router.routeProgress.currentLegProgress.stepIndex + 1)
        
        // always remove preview index when we recenter
        currentPreviewInstructionBannerStepIndex = nil
        
        removePreviewInstructions()
    }


    func removePreviewInstructions() {
        if let view = previewInstructionsView {
            view.removeFromSuperview()
            navigationView.instructionsBannerContentView.backgroundColor = InstructionsBannerView.appearance().backgroundColor
            navigationView.instructionsBannerView.delegate = self
            navigationView.instructionsBannerView.swipeable = true
            previewInstructionsView = nil
        }
    }

    @objc func toggleOverview(_ sender: Any) {
        mapView.enableFrameByFrameCourseViewTracking(for: 3)
        if let coordinates = router.route.coordinates,
            let userLocation = router.location?.coordinate {
            mapView.contentInset = contentInset(forOverviewing: true)
            mapView.setOverheadCameraView(from: userLocation, along: coordinates, for: .zero)
        }
        isInOverviewMode = true
    }

    @objc func toggleMute(_ sender: UIButton) {
        sender.isSelected = !sender.isSelected

        let muted = sender.isSelected
        NavigationSettings.shared.voiceMuted = muted
    }

    @objc func feedback(_ sender: Any) {
        showFeedback()
    }

    func showFeedback(source: FeedbackSource = .user) {
        guard let parent = parent else { return }
        let feedbackViewController = FeedbackViewController(eventsManager: navService.eventsManager)
        parent.present(feedbackViewController, animated: true, completion: nil)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        mapView.enableFrameByFrameCourseViewTracking(for: 3)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        mapView.setContentInset(contentInset(forOverviewing: isInOverviewMode), animated: true)
        mapView.setNeedsUpdateConstraints()
    }

    @objc func applicationWillEnterForeground(notification: NSNotification) {
        mapView.updateCourseTracking(location: router.location, animated: false)
    }

    func notifyUserAboutLowVolume() {
        guard !(navService.locationManager is SimulatedLocationManager) else { return }
        guard !NavigationSettings.shared.voiceMuted else { return }
        guard AVAudioSession.sharedInstance().outputVolume <= NavigationViewMinimumVolumeForWarning else { return }

        let title = String.localizedStringWithFormat(NSLocalizedString("DEVICE_VOLUME_LOW", bundle: .mapboxNavigation, value: "%@ Volume Low", comment: "Format string for indicating the device volume is low; 1 = device model"), UIDevice.current.model)
        showStatus(title: title, withSpinner: false, for: 3)
    }


    @objc func updateInstructionsBanner(notification: NSNotification) {
        guard let routeProgress = notification.userInfo?[RouteControllerNotificationUserInfoKey.routeProgressKey] as? RouteProgress else { return }
        
        // only update banner with the current step if we are not previewing our route
        if currentPreviewInstructionBannerStepIndex == nil {
            updateInstructionBanners(visualInstructionBanner: routeProgress.currentLegProgress.currentStepProgress.currentVisualInstruction)
        }
    }
    
    func updateInstructionBanners(visualInstructionBanner: VisualInstructionBanner?) {
        instructionsBannerView.update(for: visualInstructionBanner)
        lanesView.update(for: visualInstructionBanner)
        nextBannerView.update(for: visualInstructionBanner)
    }

    func updateMapOverlays(for routeProgress: RouteProgress) {
        if routeProgress.currentLegProgress.followOnStep != nil {
            mapView.addArrow(route: route, legIndex: router.routeProgress.legIndex, stepIndex: router.routeProgress.currentLegProgress.stepIndex + 1)
        } else {
            mapView.removeArrow()
        }
    }

    func updateCameraAltitude(for routeProgress: RouteProgress) {
        guard mapView.tracksUserCourse else { return } //only adjust when we are actively tracking user course

        let zoomOutAltitude = mapView.zoomedOutMotorwayAltitude
        let defaultAltitude = mapView.defaultAltitude
        let isLongRoad = routeProgress.distanceRemaining >= mapView.longManeuverDistance
        let currentStep = routeProgress.currentLegProgress.currentStep
        let upComingStep = routeProgress.currentLegProgress.upcomingStep

        //If the user is at the last turn maneuver, the map should zoom in to the default altitude.
        let currentInstruction = routeProgress.currentLegProgress.currentStepProgress.currentSpokenInstruction

        //If the user is on a motorway, not exiting, and their segment is sufficently long, the map should zoom out to the motorway altitude.
        //otherwise, zoom in if it's the last instruction on the step.
        let currentStepIsMotorway = currentStep.isMotorway
        let nextStepIsMotorway = upComingStep?.isMotorway ?? false
        if currentStepIsMotorway, nextStepIsMotorway, isLongRoad {
            setCamera(altitude: zoomOutAltitude)
        } else if currentInstruction == currentStep.lastInstruction {
            setCamera(altitude: defaultAltitude)
        }
    }

    private func showStatus(title: String, withSpinner spin: Bool = false, for duration: TimeInterval, interactive: Bool = false) {
        statusView.show(title, showSpinner: spin, interactive: interactive)
        if !duration.isInfinite {
            hideStatus(after: duration)
        }
    }
    
    func showSimulationStatus(speed: Int) {
        let format = NSLocalizedString("USER_IN_SIMULATION_MODE", bundle: .mapboxNavigation, value: "Simulating Navigation at %@×", comment: "The text of a banner that appears during turn-by-turn navigation when route simulation is enabled.")
        let title = String.localizedStringWithFormat(format, NumberFormatter.localizedString(from: speed as NSNumber, number: .decimal))
        showStatus(title: title, for: .infinity, interactive: true)
    }
    
    func hideStatus(after delay: TimeInterval = 0) {
        statusView.hide(delay: delay, animated: true)
    }

    private func setCamera(altitude: Double) {
        guard mapView.altitude != altitude else { return }
        mapView.altitude = altitude
    }


    
    /** Modifies the gesture recognizers to also update the map’s frame rate. */
    func makeGestureRecognizersResetFrameRate() {
        for gestureRecognizer in mapView.gestureRecognizers ?? [] {
            gestureRecognizer.addTarget(self, action: #selector(resetFrameRate(_:)))
        }
    }
    
    @objc func resetFrameRate(_ sender: UIGestureRecognizer) {
        mapView.preferredFramesPerSecond = NavigationMapView.FrameIntervalOptions.defaultFramesPerSecond
    }
    
    func contentInset(forOverviewing overviewing: Bool) -> UIEdgeInsets {
        let instructionBannerHeight = instructionsBannerContentView.bounds.height
        let bottomBannerHeight = bottomBannerContainerView.bounds.height
        
        var insets = UIEdgeInsets(top: instructionBannerHeight, left: 0,
                                  bottom: bottomBannerHeight, right: 0)
        
        if overviewing {
            insets += NavigationMapView.courseViewMinimumInsets
            
            let routeLineWidths = MBRouteLineWidthByZoomLevel.compactMap { $0.value.constantValue as? Int }
            insets += UIEdgeInsets(floatLiteral: Double(routeLineWidths.max() ?? 0))
        }
        
        return insets
    }

    // MARK: End Of Route

    func embedEndOfRoute() {
        let endOfRoute = endOfRouteViewController
        addChild(endOfRoute)
        navigationView.endOfRouteView = endOfRoute.view
        navigationView.constrainEndOfRoute()
        endOfRoute.didMove(toParent: self)

        endOfRoute.dismissHandler = { [weak self] (stars, comment) in
            guard let rating = self?.rating(for: stars) else { return }
            let feedback = EndOfRouteFeedback(rating: rating, comment: comment)
            self?.navService.endNavigation(feedback: feedback)
            self?.delegate?.mapViewControllerDidDismiss(self!, byCanceling: false)
        }
    }

    func unembedEndOfRoute() {
        let endOfRoute = endOfRouteViewController
        endOfRoute.willMove(toParent: nil)
        endOfRoute.removeFromParent()
    }

    func showEndOfRoute(duration: TimeInterval = 1.0, completion: ((Bool) -> Void)? = nil) {
        embedEndOfRoute()
        endOfRouteViewController.destination = destination
        navigationView.endOfRouteView?.isHidden = false

        view.layoutIfNeeded() //flush layout queue
        NSLayoutConstraint.deactivate(navigationView.bannerShowConstraints)
        NSLayoutConstraint.activate(navigationView.bannerHideConstraints)
        navigationView.endOfRouteHideConstraint?.isActive = false
        navigationView.endOfRouteShowConstraint?.isActive = true

        mapView.enableFrameByFrameCourseViewTracking(for: duration)
        mapView.setNeedsUpdateConstraints()

        let animate = {
            self.view.layoutIfNeeded()
            self.navigationView.floatingStackView.alpha = 0.0
        }

        let noAnimation = { animate(); completion?(true) }

        guard duration > 0.0 else { return noAnimation() }

        navigationView.mapView.tracksUserCourse = false
        UIView.animate(withDuration: duration, delay: 0.0, options: [.curveLinear], animations: animate, completion: completion)

        guard let height = navigationView.endOfRouteHeightConstraint?.constant else { return }
        let insets = UIEdgeInsets(top: navigationView.instructionsBannerView.bounds.height, left: 20, bottom: height + 20, right: 20)
        
        if let coordinates = route.coordinates, let userLocation = navService.router.location?.coordinate {
            let slicedLine = Polyline(coordinates).sliced(from: userLocation).coordinates
            let line = MGLPolyline(coordinates: slicedLine, count: UInt(slicedLine.count))

            let camera = navigationView.mapView.cameraThatFitsShape(line, direction: navigationView.mapView.camera.heading, edgePadding: insets)
            camera.pitch = 0
            camera.altitude = navigationView.mapView.camera.altitude
            navigationView.mapView.setCamera(camera, animated: true)
        }
    }

    fileprivate func rating(for stars: Int) -> Int {
        assert(stars >= 0 && stars <= 5)
        guard stars > 0 else { return MMEEventsManager.unrated } //zero stars means this was unrated.
        return (stars - 1) * 25
    }

    fileprivate func populateName(for waypoint: Waypoint, populated: @escaping (Waypoint) -> Void) {
        guard waypoint.name == nil else { return populated(waypoint) }
        let location = CLLocation(latitude: waypoint.coordinate.latitude, longitude: waypoint.coordinate.longitude)
        CLGeocoder().reverseGeocodeLocation(location) { (places, error) in
        guard let place = places?.first, let placeName = place.name, error == nil else { return }
            let named = Waypoint(coordinate: waypoint.coordinate, name: placeName)
            return populated(named)
        }
    }
    
    fileprivate func leg(containing step: RouteStep) -> RouteLeg? {
        return route.legs.first { $0.steps.contains(step) }
    }
}

// MARK: - UIContentContainer

extension RouteMapViewController {
    override func preferredContentSizeDidChange(forChildContentContainer container: UIContentContainer) {
        navigationView.endOfRouteHeightConstraint?.constant = container.preferredContentSize.height

        UIView.animate(withDuration: 0.3, animations: view.layoutIfNeeded)
    }
}

// MARK: - NavigationViewDelegate

extension RouteMapViewController: NavigationViewDelegate {
    // MARK: NavigationViewDelegate
    func navigationView(_ view: NavigationView, didTapCancelButton: CancelButton) {
        delegate?.mapViewControllerDidDismiss(self, byCanceling: true)
    }
    
    // MARK: VisualInstructionDelegate
    
    func label(_ label: InstructionLabel, willPresent instruction: VisualInstruction, as presented: NSAttributedString) -> NSAttributedString? {
        return delegate?.label?(label, willPresent: instruction, as: presented)
    }

    // MARK: NavigationMapViewCourseTrackingDelegate
    func navigationMapViewDidStartTrackingCourse(_ mapView: NavigationMapView) {
        navigationView.resumeButton.isHidden = true
        mapView.logoView.isHidden = false
    }

    func navigationMapViewDidStopTrackingCourse(_ mapView: NavigationMapView) {
        navigationView.resumeButton.isHidden = false
        navigationView.wayNameView.isHidden = true
        mapView.logoView.isHidden = true
    }

    //MARK: InstructionsBannerViewDelegate
    func didTapInstructionsBanner(_ sender: BaseInstructionsBannerView) {
        if stepsViewController != nil {
            stepsViewController?.dismiss() {
                self.stepsViewController = nil
            }
        } else {
            displayPreviewInstructions()
        }
        
        if currentPreviewInstructionBannerStepIndex != nil {
            recenter(self)
        }
    }
    
    func didSwipeInstructionsBanner(_ sender: BaseInstructionsBannerView, swipeDirection direction: UISwipeGestureRecognizer.Direction) {
        if direction == .down {
            displayPreviewInstructions()
            
            if currentPreviewInstructionBannerStepIndex != nil {
                recenter(self)
            }
        } else if direction == .right {
            // prevent swiping when step list is visible
            if stepsViewController != nil {
                return
            }
            
            guard let currentStepIndex = currentPreviewInstructionBannerStepIndex else { return }
            let remainingSteps = router.routeProgress.remainingSteps
            let prevStepIndex = currentStepIndex - 1
            guard prevStepIndex >= 0 else { return }
            
            let prevStep = remainingSteps[prevStepIndex]
            addPreviewInstructions(for: prevStep)
            currentPreviewInstructionBannerStepIndex = prevStepIndex
        } else if direction == .left {
            // prevent swiping when step list is visible
            if stepsViewController != nil {
                return
            }
            
            let remainingSteps = router.routeProgress.remainingSteps
            let currentStepIndex = currentPreviewInstructionBannerStepIndex ?? 0
            let nextStepIndex = currentStepIndex + 1
            guard nextStepIndex < remainingSteps.count else { return }
            
            let nextStep = remainingSteps[nextStepIndex]
            addPreviewInstructions(for: nextStep)
            currentPreviewInstructionBannerStepIndex = nextStepIndex
        }
    }
 

    private func displayPreviewInstructions() {
        removePreviewInstructions()

        if let controller = stepsViewController {
            stepsViewController = nil
            controller.dismiss()
        }
        
        let controller = StepsViewController(routeProgress: router.routeProgress)
        controller.delegate = self
        addChild(controller)
        view.insertSubview(controller.view, belowSubview: navigationView.instructionsBannerContentView)
        
        controller.view.topAnchor.constraint(equalTo: navigationView.instructionsBannerContentView.bottomAnchor).isActive = true
        controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor).isActive = true
        controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor).isActive = true
        controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor).isActive = true
        
        controller.didMove(toParent: self)
        controller.dropDownAnimation()
        
        stepsViewController = controller
    }

    //MARK: NavigationMapViewDelegate
    func navigationMapView(_ mapView: NavigationMapView, routeStyleLayerWithIdentifier identifier: String, source: MGLSource) -> MGLStyleLayer? {
        return delegate?.navigationMapView?(mapView, routeStyleLayerWithIdentifier: identifier, source: source)
    }

    func navigationMapView(_ mapView: NavigationMapView, routeCasingStyleLayerWithIdentifier identifier: String, source: MGLSource) -> MGLStyleLayer? {
        return delegate?.navigationMapView?(mapView, routeCasingStyleLayerWithIdentifier: identifier, source: source)
    }

    func navigationMapView(_ mapView: NavigationMapView, waypointStyleLayerWithIdentifier identifier: String, source: MGLSource) -> MGLStyleLayer? {
        return delegate?.navigationMapView?(mapView, waypointStyleLayerWithIdentifier: identifier, source: source)
    }

    func navigationMapView(_ mapView: NavigationMapView, waypointSymbolStyleLayerWithIdentifier identifier: String, source: MGLSource) -> MGLStyleLayer? {
        return delegate?.navigationMapView?(mapView, waypointSymbolStyleLayerWithIdentifier: identifier, source: source)
    }

    func navigationMapView(_ mapView: NavigationMapView, shapeFor waypoints: [Waypoint], legIndex: Int) -> MGLShape? {
        return delegate?.navigationMapView?(mapView, shapeFor: waypoints, legIndex: legIndex)
    }

    func navigationMapView(_ mapView: NavigationMapView, shapeFor routes: [Route]) -> MGLShape? {
        return delegate?.navigationMapView?(mapView, shapeFor: routes)
    }

    func navigationMapView(_ mapView: NavigationMapView, didSelect route: Route) {
        delegate?.navigationMapView?(mapView, didSelect: route)
    }

    func navigationMapView(_ mapView: NavigationMapView, simplifiedShapeFor route: Route) -> MGLShape? {
        return delegate?.navigationMapView?(mapView, simplifiedShapeFor: route)
    }

    func navigationMapViewUserAnchorPoint(_ mapView: NavigationMapView) -> CGPoint {
        //If the end of route component is showing, then put the anchor point slightly above the middle of the map
        if navigationView.endOfRouteView != nil, let show = navigationView.endOfRouteShowConstraint, show.isActive {
            return CGPoint(x: mapView.bounds.midX, y: (mapView.bounds.height * 0.4))
        }

        //otherwise, ask the delegate or return .zero
        return delegate?.navigationMapViewUserAnchorPoint?(mapView) ?? .zero
    }

    /**
     Updates the current road name label to reflect the road on which the user is currently traveling.

     - parameter location: The user’s current location.
     */
    func labelCurrentRoad(at rawLocation: CLLocation, for snappedLocation: CLLocation? = nil) {

        guard navigationView.resumeButton.isHidden else {
                return
        }

        let roadName = delegate?.mapViewController(self, roadNameAt: rawLocation)
        guard roadName == nil else {
            if let roadName = roadName {
                navigationView.wayNameView.text = roadName
                navigationView.wayNameView.isHidden = roadName.isEmpty
            }
            return
        }

        // Avoid aggressively opting the developer into Mapbox services if they
        // haven’t provided an access token.
        guard let _ = MGLAccountManager.accessToken else {
            navigationView.wayNameView.isHidden = true
            return
        }

        let location = snappedLocation ?? rawLocation

        labelCurrentRoadFeature(at: location)

        if let labelRoadNameCompletionHandler = labelRoadNameCompletionHandler {
            labelRoadNameCompletionHandler(true)
        }
    }

    func labelCurrentRoadFeature(at location: CLLocation) {
        guard let style = mapView.style, let stepCoordinates = router.routeProgress.currentLegProgress.currentStep.coordinates else {
                return
        }

        let closestCoordinate = location.coordinate
        let roadLabelLayerIdentifier = "roadLabelLayer"
        var streetsSources: [MGLVectorTileSource] = style.sources.compactMap {
            $0 as? MGLVectorTileSource
            }.filter {
                $0.isMapboxStreets
        }

        // Add Mapbox Streets if the map does not already have it
        if streetsSources.isEmpty {
            let source = MGLVectorTileSource(identifier: "com.mapbox.MapboxStreets", configurationURL: URL(string: "mapbox://mapbox.mapbox-streets-v8")!)
            style.addSource(source)
            streetsSources.append(source)
        }

        if let mapboxStreetsSource = streetsSources.first, style.layer(withIdentifier: roadLabelLayerIdentifier) == nil {
            let streetLabelLayer = MGLLineStyleLayer(identifier: roadLabelLayerIdentifier, source: mapboxStreetsSource)
            streetLabelLayer.sourceLayerIdentifier = mapboxStreetsSource.roadLabelLayerIdentifier
            streetLabelLayer.lineOpacity = NSExpression(forConstantValue: 1)
            streetLabelLayer.lineWidth = NSExpression(forConstantValue: 20)
            streetLabelLayer.lineColor = NSExpression(forConstantValue: UIColor.white)
            style.insertLayer(streetLabelLayer, at: 0)
        }

        let userPuck = mapView.convert(closestCoordinate, toPointTo: mapView)
        let features = mapView.visibleFeatures(at: userPuck, styleLayerIdentifiers: Set([roadLabelLayerIdentifier]))
        var smallestLabelDistance = Double.infinity
        var currentName: String?
        var currentShieldName: NSAttributedString?

        for feature in features {
            var allLines: [MGLPolyline] = []

            if let line = feature as? MGLPolylineFeature {
                allLines.append(line)
            } else if let lines = feature as? MGLMultiPolylineFeature {
                allLines = lines.polylines
            }

            for line in allLines {
                let featureCoordinates =  Array(UnsafeBufferPointer(start: line.coordinates, count: Int(line.pointCount)))
                let featurePolyline = Polyline(featureCoordinates)
                let slicedLine = Polyline(stepCoordinates).sliced(from: closestCoordinate)

                let lookAheadDistance: CLLocationDistance = 10
                guard let pointAheadFeature = featurePolyline.sliced(from: closestCoordinate).coordinateFromStart(distance: lookAheadDistance) else { continue }
                guard let pointAheadUser = slicedLine.coordinateFromStart(distance: lookAheadDistance) else { continue }
                guard let reversedPoint = Polyline(featureCoordinates.reversed()).sliced(from: closestCoordinate).coordinateFromStart(distance: lookAheadDistance) else { continue }

                let distanceBetweenPointsAhead = pointAheadFeature.distance(to: pointAheadUser)
                let distanceBetweenReversedPoint = reversedPoint.distance(to: pointAheadUser)
                let minDistanceBetweenPoints = min(distanceBetweenPointsAhead, distanceBetweenReversedPoint)

                if minDistanceBetweenPoints < smallestLabelDistance {
                    smallestLabelDistance = minDistanceBetweenPoints

                    if let line = feature as? MGLPolylineFeature {
                        let roadNameRecord = roadFeature(for: line)
                        currentShieldName = roadNameRecord.shieldName
                        currentName = roadNameRecord.roadName
                    } else if let line = feature as? MGLMultiPolylineFeature {
                        let roadNameRecord = roadFeature(for: line)
                        currentShieldName = roadNameRecord.shieldName
                        currentName = roadNameRecord.roadName
                    }
                }
            }
        }

        let hasWayName = currentName != nil || currentShieldName != nil
        if smallestLabelDistance < 5 && hasWayName  {
            if let currentShieldName = currentShieldName {
                navigationView.wayNameView.attributedText = currentShieldName
            } else if let currentName = currentName {
                navigationView.wayNameView.text = currentName
            }
            navigationView.wayNameView.isHidden = false
        } else {
            navigationView.wayNameView.isHidden = true
        }
    }

    private func roadFeature(for line: MGLPolylineFeature) -> (roadName: String?, shieldName: NSAttributedString?) {
        let roadNameRecord = roadFeatureHelper(ref: line.attribute(forKey: "ref"),
                                            shield: line.attribute(forKey: "shield"),
                                            reflen: line.attribute(forKey: "reflen"),
                                              name: line.attribute(forKey: "name"))

        return (roadName: roadNameRecord.roadName, shieldName: roadNameRecord.shieldName)
    }

    private func roadFeature(for line: MGLMultiPolylineFeature) -> (roadName: String?, shieldName: NSAttributedString?) {
        let roadNameRecord = roadFeatureHelper(ref: line.attribute(forKey: "ref"),
                                            shield: line.attribute(forKey: "shield"),
                                            reflen: line.attribute(forKey: "reflen"),
                                              name: line.attribute(forKey: "name"))

        return (roadName: roadNameRecord.roadName, shieldName: roadNameRecord.shieldName)
    }

    private func roadFeatureHelper(ref: Any?, shield: Any?, reflen: Any?, name: Any?) -> (roadName: String?, shieldName: NSAttributedString?) {
        var currentShieldName: NSAttributedString?, currentRoadName: String?

        if let text = ref as? String, let shieldID = shield as? String, let reflenDigit = reflen as? Int {
            currentShieldName = roadShieldName(for: text, shield: shieldID, reflen: reflenDigit)
        }

        if let roadName = name as? String {
            currentRoadName = roadName
        }

        if let compositeShieldImage = currentShieldName, let roadName = currentRoadName {
            let compositeShield = NSMutableAttributedString(string: " \(roadName)")
            compositeShield.insert(compositeShieldImage, at: 0)
            currentShieldName = compositeShield
        }

        return (roadName: currentRoadName, shieldName: currentShieldName)
    }

    private func roadShieldName(for text: String?, shield: String?, reflen: Int?) -> NSAttributedString? {
        guard let text = text, let shield = shield, let reflen = reflen else { return nil }

        let currentShield = HighwayShield.RoadType(rawValue: shield)
        let textColor = currentShield?.textColor ?? .black
        let imageName = "\(shield)-\(reflen)"

        guard let image = mapView.style?.image(forName: imageName) else {
            return nil
        }

        let attachment = RoadNameLabelAttachment(image: image, text: text, color: textColor, font: UIFont.boldSystemFont(ofSize: UIFont.systemFontSize), scale: UIScreen.main.scale)
        return NSAttributedString(attachment: attachment)
    }

    func showRouteIfNeeded() {
        guard isViewLoaded && view.window != nil else { return }
        guard !mapView.showsRoute else { return }
        mapView.showRoutes([router.route], legIndex: router.routeProgress.legIndex)
        mapView.showWaypoints(router.route, legIndex: router.routeProgress.legIndex)
        
        let currentLegProgress = router.routeProgress.currentLegProgress
        let nextStepIndex = currentLegProgress.stepIndex + 1
        
        if nextStepIndex <= currentLegProgress.leg.steps.count {
            mapView.addArrow(route: router.route, legIndex: router.routeProgress.legIndex, stepIndex: nextStepIndex)
        }

        if annotatesSpokenInstructions {
            mapView.showVoiceInstructionsOnMap(route: router.route)
        }
    }
    
    func addPreviewInstructions(for step: RouteStep) {
        guard let leg = leg(containing: step) else { return }
        guard let legIndex = route.legs.index(of: leg) else { return }
        guard let stepIndex = leg.steps.index(of: step) else { return }
        
        let legProgress = RouteLegProgress(leg: leg, stepIndex: stepIndex)
        guard let upcomingStep = legProgress.upcomingStep else { return }
        addPreviewInstructions(step: legProgress.currentStep, maneuverStep: upcomingStep, distance: instructionsBannerView.distance)
        
        mapView.enableFrameByFrameCourseViewTracking(for: 1)
        mapView.tracksUserCourse = false
        mapView.setCenter(upcomingStep.maneuverLocation, zoomLevel: mapView.zoomLevel, direction: upcomingStep.initialHeading!, animated: true, completionHandler: nil)
        
        guard isViewLoaded && view.window != nil else { return }
        mapView.addArrow(route: router.routeProgress.route, legIndex: legIndex, stepIndex: stepIndex + 1)
    }
    
    func addPreviewInstructions(step: RouteStep, maneuverStep: RouteStep, distance: CLLocationDistance?) {
        removePreviewInstructions()
        
        guard let instructions = step.instructionsDisplayedAlongStep?.last else { return }
        
        let instructionsView = StepInstructionsView(frame: navigationView.instructionsBannerView.frame)
        instructionsView.backgroundColor = StepInstructionsView.appearance().backgroundColor
        instructionsView.delegate = self
        instructionsView.distance = distance
        instructionsView.swipeable = true
        
        navigationView.instructionsBannerContentView.backgroundColor = instructionsView.backgroundColor
        
        view.addSubview(instructionsView)
        instructionsView.update(for: instructions)
        previewInstructionsView = instructionsView
    }
}

// MARK: StepsViewControllerDelegate

extension RouteMapViewController: StepsViewControllerDelegate {

    func stepsViewController(_ viewController: StepsViewController, didSelect legIndex: Int, stepIndex: Int, cell: StepTableViewCell) {
        
        let legProgress = RouteLegProgress(leg: router.route.legs[legIndex], stepIndex: stepIndex)
        let step = legProgress.currentStep
        guard let upcomingStep = legProgress.upcomingStep else { return }

        currentPreviewInstructionBannerStepIndex = router.routeProgress.remainingSteps.index(of: step)
        
        viewController.dismiss {
            self.addPreviewInstructions(step: step, maneuverStep: upcomingStep, distance: cell.instructionsView.distance)
            self.stepsViewController = nil
        }

        mapView.enableFrameByFrameCourseViewTracking(for: 1)
        mapView.tracksUserCourse = false
        mapView.setCenter(upcomingStep.maneuverLocation, zoomLevel: mapView.zoomLevel, direction: upcomingStep.initialHeading!, animated: true, completionHandler: nil)

        guard isViewLoaded && view.window != nil else { return }
        mapView.addArrow(route: router.route, legIndex: legIndex, stepIndex: stepIndex + 1)
    }

    func didDismissStepsViewController(_ viewController: StepsViewController) {
        viewController.dismiss {
            self.stepsViewController = nil
            self.navigationView.instructionsBannerView.stepListIndicatorView.isHidden = false
        }
    }

    @objc func didChangeSpeed(_ sender: StatusView) {
        let displayValue = 1+min(Int(9 * sender.value), 8)
        showSimulationStatus(speed: displayValue)
        
        if let locationManager = navService.locationManager as? SimulatedLocationManager {
            locationManager.speedMultiplier = Double(displayValue)
        }
    }
}

// MARK: - Keyboard Handling

extension RouteMapViewController {
    fileprivate func subscribeToKeyboardNotifications() {
        NotificationCenter.default.addObserver(self, selector: #selector(RouteMapViewController.keyboardWillShow(notification:)), name:UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(RouteMapViewController.keyboardWillHide(notification:)), name:UIResponder.keyboardWillHideNotification, object: nil)

    }
    fileprivate func unsubscribeFromKeyboardNotifications() {
        NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillHideNotification, object: nil)
    }
    @objc fileprivate func keyboardWillShow(notification: NSNotification) {
        guard navigationView.endOfRouteView != nil else { return }
        guard let userInfo = notification.userInfo else { return }
        guard let curveValue = userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int else { return }
        guard let duration = userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double else { return }
        guard let keyBoardRect = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }

        let keyboardHeight = keyBoardRect.size.height

        if #available(iOS 11.0, *) {
            navigationView.endOfRouteShowConstraint?.constant = -1 * (keyboardHeight - view.safeAreaInsets.bottom) //subtract the safe area, which is part of the keyboard's frame
        } else {
            navigationView.endOfRouteShowConstraint?.constant = -1 * keyboardHeight
        }

        let curve = UIView.AnimationCurve(rawValue: curveValue) ?? .easeIn
        let options = UIView.AnimationOptions(curve: curve) ?? .curveEaseIn
        UIView.animate(withDuration: duration, delay: 0, options: options, animations: view.layoutIfNeeded, completion: nil)
    }

    @objc fileprivate func keyboardWillHide(notification: NSNotification) {
        guard navigationView.endOfRouteView != nil else { return }
        guard let userInfo = notification.userInfo else { return }
        guard let curveValue = userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int else { return }
        guard let duration = userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double else { return }
        
        navigationView.endOfRouteShowConstraint?.constant = 0

        let curve = UIView.AnimationCurve(rawValue: curveValue) ?? .easeOut
        let options = UIView.AnimationOptions(curve: curve) ?? .curveEaseOut
        UIView.animate(withDuration: duration, delay: 0, options: options, animations: view.layoutIfNeeded, completion: nil)
    }
}

internal extension UIView.AnimationOptions {
    init?(curve: UIView.AnimationCurve) {
        switch curve {
        case .easeIn:
            self = .curveEaseIn
        case .easeOut:
            self = .curveEaseOut
        case .easeInOut:
            self = .curveEaseInOut
        case .linear:
            self = .curveLinear
        default:
            // Some private UIViewAnimationCurve values unknown to the compiler can leak through notifications.
            return nil
        }
    }
}
@objc protocol RouteMapViewControllerDelegate: NavigationMapViewDelegate, VisualInstructionDelegate {
    func mapViewControllerDidDismiss(_ mapViewController: RouteMapViewController, byCanceling canceled: Bool)
    func mapViewControllerShouldAnnotateSpokenInstructions(_ routeMapViewController: RouteMapViewController) -> Bool

    /**
     Called to allow the delegate to customize the contents of the road name label that is displayed towards the bottom of the map view.

     This method is called on each location update. By default, the label displays the name of the road the user is currently traveling on.

     - parameter mapViewController: The route map view controller that will display the road name.
     - parameter location: The user’s current location.
     - return: The road name to display in the label, or the empty string to hide the label, or nil to query the map’s vector tiles for the road name.
     */
    @objc func mapViewController(_ mapViewController: RouteMapViewController, roadNameAt location: CLLocation) -> String?
}
