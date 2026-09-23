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
            let mru = parent?.mostRecentChild
            let previousBinding = unbindFromParent()
            child.bind(to: previousBinding.parent, adaptiveWeight: previousBinding.adaptiveWeight, index: previousBinding.index)
            (child as? TilingContainer)?.unbindEmptyAndAutoFlatten(forceFlatten: forceFlatten)
            if mru != self {
                mru?.markAsMostRecentChild()
            } else {
                child.markAsMostRecentChild()
            }
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
