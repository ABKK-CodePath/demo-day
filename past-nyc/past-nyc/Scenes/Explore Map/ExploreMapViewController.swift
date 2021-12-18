//
//  ExploreMapViewController.swift
//  past-nyc
//
//  Created by Aramis on 11/25/21.
//

import CoreLocation
import MapKit

class ExploreMapViewController: UIViewController {
    
    @IBOutlet weak var exploreMap: MKMapView!
    var imageSource: ImageSource?
    
    // The last time we've looped through annotations to find the nearest 5
    var lastVicinityCheckTime = Date().addingTimeInterval(-100)
    var lastAsyncUpdate = Date().addingTimeInterval(-100)
    var lastVisibleAnnotationsUpdate = Date().addingTimeInterval(-100)
    // The 5 (or fewer) annotations that have their image popup enabled
    var activeImageAnnotations: [ImageGroup] = []
    var visibleAnnotations: Set<ImageGroup> = Set()
    fileprivate let locationManager = LocationManager.sharedInstance
    // Flag to avoid mapViewDidChangeVisibleRegion updates while the map is loading
    var mapIsLoaded = false
    // Coordinates for NYC's bounding box
    fileprivate let NYCNorthWestBound = CLLocationCoordinate2D(latitude: 40.9162, longitude: -74.2591)
    fileprivate let NYCSouthEastBound = CLLocationCoordinate2D(latitude: 40.4774, longitude: -73.7002)
    // Max and min field of view for the camera, provided in meters
    fileprivate let minCameraVisualField: Double = 400
    fileprivate let maxCameraVisualField: Double = 10000
    
    deinit {
        exploreMap.delegate = nil
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        configureAppearance()
        
        imageSource = DataLoader.main
        exploreMap.delegate = self
        
        assignBoundingBox(to: exploreMap)
        
        centerMapAroundUser()
        exploreMap.register(
            WrapperAnnotationView.self,
            forAnnotationViewWithReuseIdentifier: WrapperAnnotationView.reuseID)
        
        // Setup location manager to get current location
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didReceiveLocationNotification(_:)),
            name: .didReceiveUserLocation,
            object: nil)
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        mapViewDidChangeVisibleRegion(exploreMap)
    }
    
    @objc func didReceiveLocationNotification(_ sender: Notification) {
        centerMapAroundUser()
        // Allow these functions to run immediately
        // The entire block is scheduled 500ms in the future to allow
        // the map time to animate to the user's position
        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now().advanced(by: .milliseconds(500))) { [weak self] in
            guard let self = self else { return }
            guard let imageSource = self.imageSource else { return }
            self.lastAsyncUpdate = Date().addingTimeInterval(-10)
            // Not using a weak self ref here because the exploreMap reference is already strong
            self.asyncLoadNewAnnotations(for: self.exploreMap, fromImageSource: imageSource) {
                // showNearbyAnnotations has to be delayed again because mapView needs time
                // to add the annotations apparently
                DispatchQueue.main.asyncAfter(
                    deadline: DispatchTime.now().advanced(by: .milliseconds(100))) {
                        self.lastVisibleAnnotationsUpdate = Date().addingTimeInterval(-10)
                        self.showNearbyAnnotations(in: self.exploreMap)
                    }
            }
        }
    }
    
    fileprivate func configureAppearance() {
        navigationController?.navigationBar.titleTextAttributes = [.foregroundColor: UIColor.honeydew]
        navigationController?.navigationBar.backgroundColor = .imperialRed
    }
    
    fileprivate func centerMapAroundUser() {
        let initialRegion = MKCoordinateRegion(
            center: locationManager.userLocation ?? locationManager.defaultLocation,
            latitudinalMeters: 400,
            longitudinalMeters: 400)
        exploreMap.setRegion(initialRegion, animated: true)
        mapViewDidChangeVisibleRegion(exploreMap)
    }
    
    fileprivate func assignBoundingBox(to mapView: MKMapView) {
        let center = CLLocationCoordinate2D(
            latitude: (NYCNorthWestBound.latitude + NYCSouthEastBound.latitude) / 2,
            longitude: (NYCNorthWestBound.longitude + NYCSouthEastBound.longitude) / 2)
        let latDelta = abs(NYCNorthWestBound.latitude - NYCSouthEastBound.latitude)
        let lonDelta = abs(NYCNorthWestBound.longitude - NYCSouthEastBound.longitude)
        let coordSpan = MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)
        let boundary = MKCoordinateRegion(center: center, span: coordSpan)
        mapView.setCameraBoundary(
            MKMapView.CameraBoundary(coordinateRegion: boundary),
            animated: false)
        mapView.setCameraZoomRange(
            MKMapView.CameraZoomRange(
                minCenterCoordinateDistance: minCameraVisualField,
                maxCenterCoordinateDistance: maxCameraVisualField),
            animated: false)
    }
}

// MARK: MapView Delegate
extension ExploreMapViewController: MKMapViewDelegate {
    
    /// Creates/dequeues an annotationview for ImageGroup annotations
    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        guard annotation is ImageGroup else {return nil}
        
        var annotationView = exploreMap.dequeueReusableAnnotationView(withIdentifier: WrapperAnnotationView.reuseID)
        if annotationView == nil {
            annotationView = WrapperAnnotationView(
                annotation: annotation,
                reuseIdentifier: WrapperAnnotationView.reuseID)
        }
        
        return annotationView
    }
    
    /// Loads and pushes the relevant cluster detail view controller upon selecting a pop-up annotation
    func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
        exploreMap.deselectAnnotation(view.annotation, animated: false)
        guard let imageGroup = view.annotation as? ImageGroup else {return}
        let vc = storyboard?.instantiateViewController(
            withIdentifier: ClusterDetailViewController.storyboardID)
        guard let vc = vc as? ClusterDetailViewController else {return}
        vc.images = imageGroup.images
        navigationController?.pushViewController(vc, animated: true)
    }
    
    /// See comment on `mapIsLoaded`
    func mapViewDidFinishLoadingMap(_ mapView: MKMapView) {
        mapIsLoaded = true
    }
    
    /// Prevent too many annotations from showing at once, but only after user interaction
    /// is done, to avoid excessive flickering
    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        cullAnnotations()
    }
    
    func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
        guard mapIsLoaded,
              let source = imageSource
        else {return}
        
        attemptUpdateActivePopups(for: mapView)
        asyncLoadNewAnnotations(for: mapView, fromImageSource: source, completion: nil)
        showNearbyAnnotations(in: mapView)
    }
    
    /// Taken from https://stackoverflow.com/questions/9270268/convert-mkcoordinateregion-to-mkmaprect
    func MKMapRectForCoordinateRegion(region:MKCoordinateRegion) -> MKMapRect {
        let topLeft = CLLocationCoordinate2D(latitude: region.center.latitude + (region.span.latitudeDelta/2), longitude: region.center.longitude - (region.span.longitudeDelta/2))
        let bottomRight = CLLocationCoordinate2D(latitude: region.center.latitude - (region.span.latitudeDelta/2), longitude: region.center.longitude + (region.span.longitudeDelta/2))
        
        let a = MKMapPoint(topLeft)
        let b = MKMapPoint(bottomRight)
        
        return MKMapRect(origin: MKMapPoint(x:min(a.x,b.x), y:min(a.y,b.y)), size: MKMapSize(width: abs(a.x-b.x), height: abs(a.y-b.y)))
    }
    
    
    /// Finds the annotations nearest to a given point
    /// - Parameters:
    ///   - annotations: Annotations to search through
    ///   - center: Point from which distance is calculated
    ///   - limit: Number of annotations to return
    /// - Returns: `limit` or fewer points that are nearest to the given center point
    func nearestImageGroups(fromSet annotations: Set<AnyHashable>, toPoint center: CLLocationCoordinate2D, limit: Int) -> [ImageGroup] {
        let center = MKMapPoint(center)
        let sortedAnnotations: [ImageGroup] = annotations.filter {
            $0 is ImageGroup
        }.map {
            return $0 as! ImageGroup
        }.sorted {
            MKMapPoint($0.coordinate).distance(to: center) < MKMapPoint($1.coordinate).distance(to: center)
        }
        
        if sortedAnnotations.count < limit {
            return sortedAnnotations
        }
        return Array(sortedAnnotations[0..<limit])
    }
    
    
    /// Given two arrays of image groups, determines which were added and removed from the
    /// first to yield the second
    func annotationDifference(betweenPriorAnnotations prior: [ImageGroup], postAnnotations post: [ImageGroup]) -> (addedAnnotations: [ImageGroup], removedAnnotations: [ImageGroup]) {
        
        
        let priorIdHashes = prior.map {
            $0.objectID.hashValue
        }
        let postIdHashes = post.map {
            $0.objectID.hashValue
        }
        
        let newImageGroups = post.filter {
            !priorIdHashes.contains($0.objectID.hashValue)
        }
        let removedImageGroups = prior.filter {
            !postIdHashes.contains($0.objectID.hashValue)
        }
        
        return (addedAnnotations: newImageGroups, removedAnnotations: removedImageGroups)
    }
    
    /// Activates the five nearest annotations and ensures the others are deactivated
    fileprivate func attemptUpdateActivePopups(for mapView: MKMapView) {
        guard lastVicinityCheckTime.timeIntervalSinceNow < -0.08,
              mapIsLoaded
        else { return }
        lastVicinityCheckTime = Date()
        
        let onScreenAnnotations = mapView.annotations(in: MKMapRectForCoordinateRegion(region: mapView.region))
        let closest = nearestImageGroups(fromSet: onScreenAnnotations, toPoint: mapView.centerCoordinate, limit: 5)
        let diff = annotationDifference(betweenPriorAnnotations: activeImageAnnotations, postAnnotations: closest)
        
        activeImageAnnotations.removeAll {
            diff.removedAnnotations.contains($0)
        }
        activeImageAnnotations.append(contentsOf: diff.addedAnnotations)
        
        diff.removedAnnotations.forEach {
            if let group = exploreMap.view(for: $0) as? WrapperAnnotationView {
                group.deactivate()
            }
        }
        diff.addedAnnotations.forEach {
            if let group = exploreMap.view(for: $0) as? WrapperAnnotationView {
                group.activate()
            }
        }
    }
    
    
    /// Makes visible only the annotation within view
    /// This is done to minimize calls to MKMapView.addAnnotation
    /// The mapview will maintain many annotations, but most will have their views hidden
    fileprivate func showNearbyAnnotations(in mapView: MKMapView) {
        guard lastVisibleAnnotationsUpdate.timeIntervalSinceNow < 0.1,
              mapIsLoaded
        else { return }
        lastVisibleAnnotationsUpdate = Date()
        
        let onScreen = mapView
            .annotations(in: MKMapRectForCoordinateRegion(region: mapView.region))
            .filter {
                $0 is ImageGroup
            } as? Set<ImageGroup>
        guard let onScreen = onScreen else {
            // This shouldn't ever be triggered
            print("Failed to cast onScreen to Set<ImageGroup> in showNearbyAnnotations(in:)")
            return
        }
        
        let nearby = onScreen.filter {
            MKMapPoint($0.coordinate).distance(to: MKMapPoint(mapView.region.center)) < 500
        }
        let offScreen = visibleAnnotations.subtracting(nearby)
        
        offScreen.forEach {
            mapView.view(for: $0)?.isHidden = true
        }
        
        nearby.forEach {
            mapView.view(for: $0)?.isHidden = false
        }
        
        visibleAnnotations = nearby
    }
    
    /// Removes all annotations greater than 800m from the map center
    fileprivate func cullAnnotations() {
        let farAnnotations = exploreMap.annotations.filter {
            $0 is ImageGroup &&
            MKMapPoint($0.coordinate).distance(to: MKMapPoint(exploreMap.centerCoordinate)) > 3000
        }
        exploreMap.removeAnnotations(farAnnotations)
    }
    
    fileprivate func asyncLoadNewAnnotations(
        for mapView: MKMapView,
        fromImageSource imageSource: ImageSource,
        completion: (() -> ())?
    ) {
        guard lastAsyncUpdate.timeIntervalSinceNow < -3,
              mapIsLoaded
        else { return }
        lastAsyncUpdate = Date()
        
        // This cast should never fail because of the filter condition
        let priorAnnotations = exploreMap.annotations.filter( {$0 is ImageGroup} ) as? [ImageGroup]
        guard let priorAnnotations = priorAnnotations else {
            fatalError("Failed to cast priorAnnotations to [ImageGroup] in asyncLoadNewAnnotations(for:fromImageSoruce:")
        }
        
        let priorIDs = Set(priorAnnotations.map({ $0.uniqueID }))
        
        let regionCenter = mapView.region.center
        let bigRegion = MKCoordinateRegion(center: regionCenter, latitudinalMeters: 2000, longitudinalMeters: 2000)
        
        imageSource.asyncNewImages(
            inRegion: bigRegion,
            withPriorImageIDs: priorIDs
        ) { [weak mapView] update in
            guard update.count > 0 else { return }
            mapView?.addAnnotations(update)
            print(mapView?.annotations.count)
            completion?()
        }
    }
}
