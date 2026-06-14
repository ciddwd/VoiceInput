import Foundation

/// Reads the current task's `phys_footprint` — the exact metric iOS jetsam uses
/// to decide when to kill an app extension for exceeding its memory budget.
/// Resident size / `resident_size` is misleading here; phys_footprint is what
/// matters for "will the keyboard get killed?".
enum MemoryProbe {
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size) / 4
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return -1 }
        return Double(info.phys_footprint) / 1024.0 / 1024.0
    }
}
