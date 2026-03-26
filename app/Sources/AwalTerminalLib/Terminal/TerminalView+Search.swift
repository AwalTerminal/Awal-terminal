import AppKit
import CAwalTerminal

// MARK: - Search

extension TerminalView {

    /// Set the search query in the search bar (opens search if not visible).
    func setSearchQuery(_ query: String) {
        if searchBar == nil {
            toggleSearch()
        }
        searchBar?.setQuery(query)
    }

    func toggleSearch() {
        if searchBar != nil {
            closeSearch()
        } else {
            openSearch()
        }
    }

    func openSearch() {
        guard searchBar == nil else { return }

        let bar = SearchBarView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])

        bar.onClose = { [weak self] in
            self?.closeSearch()
        }
        bar.onSearchChanged = { [weak self] query in
            self?.performSearch(query)
        }
        bar.onNextMatch = { [weak self] in
            self?.navigateSearch(forward: true)
        }
        bar.onPrevMatch = { [weak self] in
            self?.navigateSearch(forward: false)
        }

        searchBar = bar
        bar.activate()
    }

    func closeSearch() {
        searchBar?.removeFromSuperview()
        searchBar = nil
        searchResults = []
        currentSearchIndex = 0
        window?.makeFirstResponder(self)
        needsRender = true
    }

    func performSearch(_ query: String) {
        guard let s = surface else { return }
        searchResults = []
        currentSearchIndex = 0
        searchQueryLength = query.count
        contentDirty = true

        if query.isEmpty {
            searchBar?.updateMatchCount(current: 0, total: 0)
            needsRender = true
            return
        }

        var results = [ATSearchResult](repeating: ATSearchResult(col: 0, row: 0), count: 1000)
        let count = query.withCString { cQuery in
            results.withUnsafeMutableBufferPointer { buf in
                at_surface_search(s, cQuery, buf.baseAddress!, UInt32(buf.count))
            }
        }

        searchResults = (0..<Int(count)).map { i in
            (col: Int(results[i].col), row: results[i].row)
        }

        if !searchResults.isEmpty {
            // Find the closest result to current viewport
            let viewportOffset = at_surface_get_viewport_offset(s)
            let scrollbackLen = at_surface_get_scrollback_len(s)
            let viewportTopRow = Int32(-scrollbackLen + (scrollbackLen - viewportOffset))
            var closest = 0
            var closestDist = Int32.max
            for (i, result) in searchResults.enumerated() {
                let dist = abs(result.row - viewportTopRow)
                if dist < closestDist {
                    closestDist = dist
                    closest = i
                }
            }
            currentSearchIndex = closest
        }

        searchBar?.updateMatchCount(current: searchResults.isEmpty ? 0 : currentSearchIndex + 1,
                                     total: searchResults.count)
        scrollToCurrentMatch()
    }

    func navigateSearch(forward: Bool) {
        guard !searchResults.isEmpty else { return }
        if forward {
            currentSearchIndex = (currentSearchIndex + 1) % searchResults.count
        } else {
            currentSearchIndex = (currentSearchIndex - 1 + searchResults.count) % searchResults.count
        }
        searchBar?.updateMatchCount(current: currentSearchIndex + 1, total: searchResults.count)
        scrollToCurrentMatch()
    }

    func scrollToCurrentMatch() {
        guard let s = surface, !searchResults.isEmpty else { return }

        let match = searchResults[currentSearchIndex]
        let scrollbackLen = Int(at_surface_get_scrollback_len(s))
        let rows = Int(termRows)

        // Convert absolute row to viewport offset needed to show it
        // match.row: negative = scrollback, 0+ = screen row
        // We want the match to be roughly centered in the viewport
        if match.row < 0 {
            // Scrollback match: row is -(scrollbackLen) to -1
            // Offset needed = distance from bottom of scrollback
            let sbIndex = scrollbackLen + Int(match.row) // 0-based index into scrollback
            let targetOffset = scrollbackLen - sbIndex - rows / 2
            let clampedOffset = max(0, min(targetOffset, scrollbackLen))
            // Reset to bottom, then scroll up
            at_surface_scroll_viewport(s, Int32(-scrollbackLen))
            at_surface_scroll_viewport(s, Int32(clampedOffset))
        } else {
            // On-screen match — go to live view
            at_surface_scroll_viewport(s, Int32(-scrollbackLen))
        }

        updateCellBuffer()
        needsRender = true
    }

    func computeVisibleSearchHighlights() -> (cells: [(col: Int, row: Int, len: Int)], currentIndex: Int) {
        guard let s = surface, !searchResults.isEmpty else { return ([], -1) }

        let viewportOffset = Int(at_surface_get_viewport_offset(s))
        let rows = Int(termRows)
        let cols = Int(termCols)

        // The viewport shows rows from (scrollbackLen - viewportOffset - rows) to (scrollbackLen - viewportOffset - 1)
        // in absolute terms. But our search results use: negative = scrollback, 0+ = screen.
        // Convert viewport to absolute row range:
        // Viewport top absolute row = -(viewportOffset + rows) .. -(viewportOffset) for scrollback,
        //   or 0..(rows-1) for screen rows when viewportOffset==0

        // Absolute row of viewport top: if offset=0 → screen row 0, if offset>0 → negative
        let viewportTopAbs: Int = -viewportOffset
        let viewportBottomAbs: Int = viewportTopAbs + rows - 1

        var highlights: [(col: Int, row: Int, len: Int)] = []
        var currentIdx = -1

        for (i, result) in searchResults.enumerated() {
            let absRow = Int(result.row)
            if absRow >= viewportTopAbs && absRow <= viewportBottomAbs {
                let screenRow = absRow - viewportTopAbs
                let clampedLen = min(searchQueryLength, cols - result.col)
                if clampedLen > 0 {
                    if i == currentSearchIndex {
                        currentIdx = highlights.count
                    }
                    highlights.append((col: result.col, row: screenRow, len: clampedLen))
                }
            }
        }

        return (highlights, currentIdx)
    }
}
