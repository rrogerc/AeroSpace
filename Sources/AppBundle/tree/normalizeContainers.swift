extension Workspace {
    @MainActor func normalizeContainers() {
        // Beware! rootTilingContainer may change after this line of code
        // Dwindle relies on flattening: when a window closes, the other half of its split takes the whole split
        rootTilingContainer.unbindEmptyAndAutoFlatten(forceFlatten: isDwindle)
        if isDwindle {
            normalizeDwindleShape()
        } else if config.enableNormalizationOppositeOrientationForNestedContainers {
            rootTilingContainer.normalizeOppositeOrientationForNestedContainers()
        }
    }
}

extension TilingContainer {
    @MainActor fileprivate func unbindEmptyAndAutoFlatten(forceFlatten: Bool) {
        if let child = children.singleOrNil(), config.enableNormalizationFlattenContainers || forceFlatten, child is TilingContainer || !isRootContainer {
            child.unbindFromParent()
            // Binding would make the child the most recent up to the workspace, although closing its sibling focused
            // nothing. E.g. a fullscreen window in another branch would stop being the most recent and leave fullscreen
            replace(with: child)
            (child as? TilingContainer)?.unbindEmptyAndAutoFlatten(forceFlatten: forceFlatten)
        } else {
            for child in children {
                (child as? TilingContainer)?.unbindEmptyAndAutoFlatten(forceFlatten: forceFlatten)
            }
            if children.isEmpty && !isRootContainer {
                unbindFromParent()
            }
        }
    }
}
