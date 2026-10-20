# DiskSunburst — specification

**Tagline:** Scan a folder or drive and see what eats your space in an interactive sunburst chart, then reveal or trash it.

**Category:** Files & Conversion

**Inspired by (paid):** DaisyDisk ($9.99 one-time)

**Frameworks:** SwiftUI, AppKit, Foundation, UniformTypeIdentifiers, CoreGraphics

**Donation URL (Support button):** https://ko-fi.com/leodavidai

## Spec

What the paid app does and evidence of demand. DaisyDisk scans a disk and draws its folders as concentric rings so you can spot huge files at a glance and clean them up. It is sold in the Mac App Store at 9.99 dollars, has held a near perfect star rating for years, is covered by Macworld and is recommended constantly in threads about freeing up space, which makes it one of the most recommended paid disk utilities. Our version delivers the core visual scan, drill down and cleanup with no extras.

Feature set for our clean-room version. A window app. Choose a folder or the whole home folder, press Scan, and a background scan walks the tree summing allocated file sizes. Progress shows the current folder and bytes counted. The result is a sunburst chart: the center is the scanned folder, each ring is one level deeper, and each arc has an angle proportional to size. Hovering an arc shows name, size and share of the parent in a footer. Clicking a folder arc drills in and makes it the new center, with a breadcrumb to go back up. A side list shows the largest children with size bars. Actions on a selection: Reveal in Finder, Open, Copy Path and Move to Trash after a confirmation. Arcs are colored by hue per top-level branch with lightness changing by depth. Tiny items under one percent are merged into a gray Smaller items arc.

UI spec. A single window with toolbar buttons Choose Folder, Rescan and Up. Left two thirds is the chart drawn in a SwiftUI Canvas, right third is the sorted list. A status bar shows total scanned size and the free space of the volume. Settings are small: show hidden files, treat packages such as app bundles as single items, and the maximum ring depth, default 5. Empty state: a large drop target saying Drop a folder here or press Choose Folder. Keyboard: Command O to choose, Command R to rescan, Delete to trash the selected item, Escape to go up.

Technical approach. Walk directories with FileManager enumerator using URLResourceValues keys for total file allocated size, file size, is directory and is package. Run the walk in a detached task, build an immutable tree of nodes with name, size and children, and publish snapshots periodically to the main actor so the chart updates while scanning. Compute arc geometry by recursion, with a minimum angle threshold for drawing. Hit-testing converts the pointer location to polar coordinates to find the arc. Drag and drop uses onDrop with UTType fileURL. Trash with NSWorkspace recycle so items stay recoverable. Folders such as Desktop and Documents trigger the system privacy prompts when first read, and full-disk scanning needs the user to grant Full Disk Access manually, so explain this in the empty state with a button opening the privacy settings.

Edge cases and error handling. Skip symbolic links to avoid loops and double counting, and skip the firmlinked system volumes unless chosen. Report folders that could not be read as a count with a hint about permissions rather than failing. Hard links are counted once using file identifiers. Cancel the scan cleanly when the window closes or a new scan starts. Handle very large trees by limiting stored children per node to the largest few hundred plus one aggregate node. Refuse to trash the scan root itself. Keep the code near 600 lines.
