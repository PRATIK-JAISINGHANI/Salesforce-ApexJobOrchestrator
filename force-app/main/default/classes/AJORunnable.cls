/**
 * The contract for jobs written against the orchestrator.
 * Existing Schedulable / Batchable / Queueable classes do not implement this —
 * they are called through AJOLegacyAdapter and are not modified.
 */
public interface AJORunnable {
    void run(AJOContext ctx);
}