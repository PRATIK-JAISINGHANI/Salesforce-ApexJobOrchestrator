/**
 * Carries a job from its heartbeat to its exact configured minute.
 * The platform caps the queueable delay at 10 minutes, which is why the
 * heartbeat interval is 10 rather than 15 — any minute stays reachable.
 */
public with sharing class AJODeferredRunner implements Queueable {

    private final Id jobId;
    private final Datetime dueAt;

    public AJODeferredRunner(Id jobId, Datetime dueAt) {
        this.jobId = jobId;
        this.dueAt = dueAt;
    }

    public void execute(QueueableContext qc) {
        List<AJOJob__c> jobs = Database.query(
            'SELECT ' + AJOLauncher.JOB_FIELDS
            + ' FROM AJOJob__c WHERE Id = :jobId LIMIT 1');
        if (jobs.isEmpty()) { return; }

        AJOJob__c job = jobs[0];

        // Re-checked rather than trusted: up to ten minutes passed since the
        // heartbeat queued this, and any of it may have changed in between.
        // The kill switch is included because "Pause all jobs" has to mean
        // nothing starts — a run already sitting in the queue was previously
        // able to fire straight through a pause.
        if (AJOConfig.killSwitch()
            || !AJOWindow.isActive(job)
            || job.AJO_Status__c == 'Suspended'
            || job.AJO_Status__c == 'Expired') {
            release(job);
            return;
        }

        // Re-checked that this run still owns the occurrence. An edit, resume or
        // window change recomputes Next Run from now; when that lands on or
        // before this instant the heartbeat starts the occurrence itself, and
        // starting it here too ran the job twice. Status is not used for this:
        // settling an earlier run can move a queued job back to Idle.
        if (job.AJO_QueuedForAt__c != dueAt
            || (job.AJO_NextRunAt__c != null && job.AJO_NextRunAt__c <= dueAt)) {
            // A marker naming another instant belongs to another queued run.
            if (job.AJO_QueuedForAt__c == dueAt) { release(job); }
            return;
        }

        AJOLauncher.runNow(job, dueAt, 'Heartbeat', null);
        job.AJO_QueuedForAt__c = null;
        update job;
    }

    /**
      * Clears the queued marker on a run that will not start after all, so the
      * console does not go on promising a run that was abandoned.
      */
    private static void release(AJOJob__c job) {
        if (job.AJO_QueuedForAt__c == null) { return; }
        try {
            update new AJOJob__c(Id = job.Id, AJO_QueuedForAt__c = null);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'AJO could not clear the queued marker: ' + e.getMessage());
        }
    }
}