/**
 * Decides what actually starts, and starts it.
 *
 * Order of checks per job: circuit breaker, dependency, overlap, dry run,
 * throttle, minute deferral, then launch. Every branch leaves a run record
 * behind, so a job that did not run is visible rather than silent.
 */
public with sharing class AJOLauncher {

    /** Queueable jobs allowed per transaction is 50; leave headroom. */
    private static final Integer MAX_DEFERRALS_PER_HEARTBEAT = 40;

    public static void launch(List<AJOJob__c> jobs, Integer slot) {
        if (jobs == null || jobs.isEmpty()) { return; }

        AJOThrottle throttle = new AJOThrottle();
        Datetime now = Datetime.now();
        Integer deferrals = 0;

        List<AJOJob__c> toUpdate = new List<AJOJob__c>();
        List<AJOJobRun__c> notes = new List<AJOJobRun__c>();

        for (AJOJob__c job : jobs) {
            Datetime dueAt = job.AJO_NextRunAt__c;
            try {
                if (job.AJO_Status__c == 'Suspended') {
                    continue;
                }

                // Defence in depth. The dispatcher already filtered on the
                // window, but runNow and the deferred path share this method.
                if (!AJOWindow.isActive(job)) {
                    notes.add(noteRecord(job, dueAt, 'Skipped',
                        'Outside its activation window: ' + AJOWindow.describe(job), slot));
                    advance(job, now);
                    toUpdate.add(job);
                    continue;
                }

                if (job.AJO_DependsOnJobId__c != null && !dependencySatisfied(job)) {
                    notes.add(noteRecord(job, dueAt, 'Skipped',
                        'Waiting on dependency ' + job.AJO_DependsOnJobId__c, slot));
                    advance(job, now);
                    toUpdate.add(job);
                    continue;
                }

                if (job.AJO_Status__c == 'Running' && job.AJO_OverlapPolicy__c != 'Allow') {
                    notes.add(noteRecord(job, dueAt, 'Skipped',
                        'Previous run still in progress; overlap policy is '
                        + job.AJO_OverlapPolicy__c, slot));
                    if (job.AJO_OverlapPolicy__c == 'Skip') { advance(job, now); }
                    toUpdate.add(job);
                    continue;
                }

                if (job.AJO_DryRun__c == true) {
                    notes.add(noteRecord(job, dueAt, 'Dry Run',
                        'Shadow mode: would have started ' + job.AJO_ApexClassName__c
                        + ' as ' + job.AJO_ExecutionType__c, slot));
                    job.AJO_LastRunStatus__c = 'Dry Run';
                    job.AJO_LastRunAt__c = now;
                    advance(job, now);
                    toUpdate.add(job);
                    continue;
                }

                if (!throttle.claim(job)) {
                    notes.add(noteRecord(job, dueAt, 'Throttled',
                        'No batch slot free (' + AJOConfig.maxConcurrentBatches()
                        + ' concurrent maximum). Retrying at the next heartbeat.', slot));
                    // NextRunAt is deliberately left alone so it is picked up again.
                    continue;
                }

                Integer delay = deferralMinutes(dueAt, now);
                if (delay > 0 && AJOConfig.deferralEnabled()
                    && deferrals < MAX_DEFERRALS_PER_HEARTBEAT) {
                    enqueueDeferred(job.Id, dueAt, delay);
                    deferrals++;
                    job.AJO_Status__c = 'Queued';
                    // Remembered because advance() below moves NextRunAt past the
                    // instant just queued. Without this the console has no way to
                    // say "queued, starts at 15:00" and the job simply vanishes
                    // from the preview until its next occurrence.
                    job.AJO_QueuedForAt__c = dueAt;
                    // Advance past the deferred instant, not past now. Advancing
                    // from now leaves NextRunAt inside the current window, so a
                    // second heartbeat firing before the deferred run lands would
                    // queue the same job again.
                    advance(job, dueAt);
                    toUpdate.add(job);
                    continue;
                }

                runNow(job, dueAt, 'Heartbeat', slot);
                advance(job, now);
                toUpdate.add(job);

            } catch (Exception e) {
                // One bad job must never stop the rest of the heartbeat.
                notes.add(noteRecord(job, dueAt, 'Failed',
                    e.getTypeName() + ': ' + e.getMessage(), slot));
                job.AJO_LastRunStatus__c = 'Failed';
                job.AJO_LastRunAt__c = now;
                job.AJO_ConsecutiveFailures__c =
                    (job.AJO_ConsecutiveFailures__c == null ? 0 : job.AJO_ConsecutiveFailures__c) + 1;
                if (job.AJO_MaxConsecutiveFailures__c != null
                    && job.AJO_MaxConsecutiveFailures__c > 0
                    && job.AJO_ConsecutiveFailures__c >= job.AJO_MaxConsecutiveFailures__c) {
                    job.AJO_Status__c = 'Suspended';
                } else {
                    job.AJO_Status__c = 'Idle';
                }
                advance(job, now);
                toUpdate.add(job);
            }
        }

        if (!notes.isEmpty())    { insert notes; }
        if (!toUpdate.isEmpty()) { update toUpdate; }
    }

    /**
     * Starts one job immediately. Mutates the job in memory; the caller commits.
     * Used by the heartbeat, the deferred runner and the console's Run now.
     */
    public static AJOJobRun__c runNow(AJOJob__c job, Datetime dueAt,
                                      String triggeredBy, Integer slot) {
        AJOJobRun__c run = AJORunLogger.open(job, dueAt, triggeredBy, slot);
        job.AJO_LastRunAt__c = Datetime.now();

        try {
            if (job.AJO_ExecutionType__c == 'Runnable') {
                Object o = AJOLegacyAdapter.instantiate(job.AJO_ApexClassName__c);
                if (!(o instanceof AJORunnable)) {
                    throw new AJOLegacyAdapter.UnsupportedJobException(
                        job.AJO_ApexClassName__c + ' does not implement AJORunnable.');
                }
                AJOContext ctx = new AJOContext(job, run);
                ((AJORunnable) o).run(ctx);

                run.AJO_ItemsProcessed__c = ctx.itemsProcessed;
                run.AJO_ItemsFailed__c    = ctx.itemsFailed;
                run.AJO_Message__c        = ctx.message;
                run.AJO_BatchSize__c      = ctx.batchSize;
                job.AJO_ConsecutiveFailures__c = 0;

                if (ctx.asyncJobId != null) {
                    // The Runnable started work of its own that outlives this
                    // transaction. Treated exactly like a directly registered
                    // Batch: the id is recorded, the run stays open, and a later
                    // heartbeat closes it against AsyncApexJob. Closing it here
                    // would report Success and a fraction of a second while the
                    // real work had not begun.
                    run.AJO_AsyncApexJobId__c = ctx.asyncJobId;
                    job.AJO_LastAsyncApexJobId__c = ctx.asyncJobId;
                    if (String.isBlank(run.AJO_Message__c)) {
                        run.AJO_Message__c = 'Launched as Batch; awaiting platform completion.';
                    }
                    update AJORunLogger.patch(run);
                    job.AJO_Status__c        = 'Running';
                    job.AJO_LastRunStatus__c = null;
                    return run;
                }

                AJORunLogger.close(run, 'Success', null);
                job.AJO_Status__c            = 'Idle';
                job.AJO_LastRunStatus__c     = 'Success';
                job.AJO_LastDurationSec__c   = run.AJO_DurationSec__c;
                return run;
            }

            AJOLegacyAdapter.Outcome out = AJOLegacyAdapter.run(
                job.AJO_ApexClassName__c,
                job.AJO_ExecutionType__c,
                job.AJO_BatchSize__c == null ? null : job.AJO_BatchSize__c.intValue());

            job.AJO_LastAsyncApexJobId__c = out.asyncJobId;
            run.AJO_BatchSize__c = out.scopeUsed;

            if (out.asyncJobId == null) {
                // Ran synchronously inside this transaction — outcome is known.
                run.AJO_Message__c = 'Ran synchronously as ' + out.mode
                    + '. Any async work it started itself is not tracked by this run '
                    + '— register the batch class directly, or implement AJORunnable.';
                AJORunLogger.close(run, 'Success', null);
                job.AJO_Status__c          = 'Idle';
                job.AJO_LastRunStatus__c   = 'Success';
                job.AJO_LastDurationSec__c = run.AJO_DurationSec__c;
            } else {
                // Async work outlives this transaction. Left open; a later
                // heartbeat reconciles it against AsyncApexJob.
                run.AJO_AsyncApexJobId__c = out.asyncJobId;
                run.AJO_Message__c = 'Launched as ' + out.mode
                                 + '; awaiting platform completion.';
                update AJORunLogger.patch(run);
                job.AJO_Status__c        = 'Running';
                job.AJO_LastRunStatus__c = null;
            }
            job.AJO_ConsecutiveFailures__c = 0;
            return run;

        } catch (Exception e) {
            // Logging the failure must not itself be able to throw, or the
            // outer heartbeat handler would count this job as failed twice.
            try {
                AJORunLogger.fail(run, e);
            } catch (Exception logError) {
                System.debug(LoggingLevel.ERROR,
                    'AJO could not write the failure for ' + job.AJO_JobKey__c
                    + ': ' + logError.getMessage());
            }
            job.AJO_Status__c        = 'Idle';
            job.AJO_LastRunStatus__c = 'Failed';
            job.AJO_LastDurationSec__c = run.AJO_DurationSec__c;
            job.AJO_ConsecutiveFailures__c =
                (job.AJO_ConsecutiveFailures__c == null ? 0 : job.AJO_ConsecutiveFailures__c) + 1;
            if (job.AJO_MaxConsecutiveFailures__c != null
                && job.AJO_MaxConsecutiveFailures__c > 0
                && job.AJO_ConsecutiveFailures__c >= job.AJO_MaxConsecutiveFailures__c) {
                job.AJO_Status__c = 'Suspended';
            }
            return run;
        }
    }

    /**
      * Recomputes NextRunAt forward from now. Missed windows never accumulate.
      *
      * When the next occurrence falls past the job's End Date there is nothing
      * left to schedule, so NextRunAt is cleared and the job is marked Expired.
      * Leaving a stale NextRunAt behind would have the heartbeat re-examine and
      * re-reject the job on every pass for the rest of the org's life.
      *
      * A job whose window has not opened yet is advanced from the Start Date
      * rather than from now, so the Next Run it reports is the first occurrence
      * it is actually allowed to take instead of one it will silently skip.
      */
    public static void advance(AJOJob__c job, Datetime fromMoment) {
        try {
            Datetime opensAt = AJOWindow.opensAt(job);
            Datetime searchFrom = (opensAt != null && opensAt > fromMoment)
                                  ? opensAt : fromMoment;

            Datetime nextRun = AJOCron.next(
                job.AJO_CronExpression__c, searchFrom,
                String.isBlank(job.AJO_TimeZoneSidKey__c)
                    ? AJOConfig.defaultTimeZone() : job.AJO_TimeZoneSidKey__c);

            if (nextRun != null && AJOWindow.isBeyondWindow(job, nextRun)) {
                job.AJO_NextRunAt__c = null;
                // A job whose last occurrence is still in flight keeps its
                // runtime status; AJORunLogger marks it Expired once it settles.
                if (job.AJO_Status__c != 'Running') { job.AJO_Status__c = 'Expired'; }
                return;
            }
            job.AJO_NextRunAt__c = nextRun;
            if (job.AJO_Status__c == 'Expired' && !AJOWindow.hasExpired(job)) {
                // The window was extended, so the job is schedulable again.
                job.AJO_Status__c = 'Idle';
            }
        } catch (Exception e) {
            // An unparseable expression must not wedge the heartbeat.
            job.AJO_NextRunAt__c = null;
            job.AJO_Status__c = 'Suspended';
        }
    }

    /**
      * How many minutes a job that is due later in this heartbeat's window must
      * wait. Public because the console previews the same answer without
      * launching anything.
      */
    public static Integer deferralMinutes(Datetime dueAt, Datetime now) {
        if (dueAt == null || dueAt <= now) { return 0; }
        Long diffMs = dueAt.getTime() - now.getTime();
        // Rounded up, not down. A heartbeat that fires one second late leaves a
        // 9m59s gap to the next minute, and flooring that to 9 started the job a
        // minute BEFORE its configured time. Late by seconds is correct; early is
        // not. The platform cap below keeps the result legal.
        Integer mins = (Integer) Math.ceil(diffMs / 60000.0);
        if (mins <= 0) { return 0; }
        return Math.min(mins, AJOConfig.PLATFORM_DELAY_CAP);
    }

    private static void enqueueDeferred(Id jobId, Datetime dueAt, Integer delayMinutes) {
        AsyncOptions opts = new AsyncOptions();
        opts.MinimumQueueableDelayInMinutes = delayMinutes;
        System.enqueueJob(new AJODeferredRunner(jobId, dueAt), opts);
    }

    private static Boolean dependencySatisfied(AJOJob__c job) {
        List<AJOJobRun__c> last = [
            SELECT AJO_Status__c
            FROM   AJOJobRun__c
            WHERE  AJO_Job__c = :job.AJO_DependsOnJobId__c
              AND  AJO_StartedAt__c = TODAY
            ORDER BY AJO_StartedAt__c DESC
            LIMIT  1
        ];
        return !last.isEmpty() && last[0].AJO_Status__c == 'Success';
    }

    private static AJOJobRun__c noteRecord(AJOJob__c job, Datetime dueAt,
                                           String status, String message, Integer slot) {
        return new AJOJobRun__c(
            AJO_Job__c           = job.Id,
            AJO_StartedAt__c     = Datetime.now(),
            AJO_FinishedAt__c    = Datetime.now(),
            AJO_DurationSec__c   = 0,
            AJO_Status__c        = status,
            AJO_TriggeredBy__c   = 'Heartbeat',
            AJO_ScheduledFor__c  = dueAt,
            AJO_HeartbeatSlot__c = slot,
            AJO_Message__c       = message != null && message.length() > 4000
                               ? message.substring(0, 4000) : message
        );
    }

    public static final String JOB_FIELDS =
        'Id, Name, AJO_JobKey__c, AJO_ExecutionType__c, AJO_ApexClassName__c, AJO_BatchSize__c, '
        + 'AJO_CronExpression__c, AJO_TimeZoneSidKey__c, AJO_IsActive__c, AJO_DryRun__c, AJO_Status__c, '
        + 'AJO_NextRunAt__c, AJO_LastRunAt__c, AJO_LastRunStatus__c, AJO_LastDurationSec__c, '
        + 'AJO_LastAsyncApexJobId__c, AJO_OverlapPolicy__c, AJO_Priority__c, AJO_MaxRuntimeMinutes__c, '
        + 'AJO_ConsecutiveFailures__c, AJO_MaxConsecutiveFailures__c, AJO_Parameters__c, '
        + 'AJO_DependsOnJobId__c, AJO_NotifyEmails__c, AJO_LegacyCronJobName__c, '
        + 'AJO_LegacyCronExpression__c, AJO_Pinned__c, AJO_Description__c, '
        + 'AJO_Enabled__c, AJO_StartDate__c, AJO_EndDate__c, AJO_WindowStatus__c, '
        + 'AJO_QueuedForAt__c, AJO_LegacyCronTriggerId__c';
}