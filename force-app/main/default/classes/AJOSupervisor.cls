/**
 * The piece that makes the framework safe to leave alone.
 * Re-arms missing heartbeats, closes out async runs, reaps stuck ones,
 * retires jobs whose activation window has closed, and enforces log retention
 * against an org already over its storage limit.
 */
global with sharing class AJOSupervisor implements Schedulable {

    global void execute(SchedulableContext sc) { sweep(); }

    public static Map<String, Object> sweep() {
        Map<String, Object> result = new Map<String, Object>();
        result.put('reconciled', safeReconcile());
        result.put('stuck',      reapStuck());
        result.put('expired',    expireLapsed());
        result.put('purged',     purge());
        result.put('unqueued',   clearLapsedQueue());
        result.put('rearmed',    AJOInstaller.rearmMissing());
        result.put('slotsUsed',  AJOInstaller.scheduledApexSlotsUsed());
        return result;
    }

    private static Integer safeReconcile() {
        try { return AJORunLogger.reconcile(); }
        catch (Exception e) { return -1; }
    }

    /** A run past its job's MaxRuntimeMinutes is marked Stuck and the job freed. */
    public static Integer reapStuck() {
        List<AJOJobRun__c> openRuns = [
            SELECT Id, AJO_Job__c, AJO_StartedAt__c, AJO_FinishedAt__c, AJO_Status__c,
                   AJO_DurationSec__c, AJO_AsyncApexJobId__c, AJO_ItemsProcessed__c,
                   AJO_ItemsFailed__c, AJO_BatchSize__c, AJO_Message__c,
                   AJO_ErrorMessage__c, AJO_StackTrace__c,
                   AJO_Job__r.AJO_MaxRuntimeMinutes__c
            FROM   AJOJobRun__c
            WHERE  AJO_Status__c = 'Running'
              AND  AJO_StartedAt__c = LAST_N_DAYS:7
            LIMIT  500
        ];
        List<AJOJobRun__c> stuck = new List<AJOJobRun__c>();
        Set<Id> jobIds = new Set<Id>();
        Datetime now = Datetime.now();

        for (AJOJobRun__c r : openRuns) {
            Decimal cap = r.AJO_Job__r.AJO_MaxRuntimeMinutes__c;
            Integer limitMins = (cap == null || cap <= 0) ? 240 : cap.intValue();
            if (r.AJO_StartedAt__c.addMinutes(limitMins) < now) {
                r.AJO_Status__c       = 'Stuck';
                r.AJO_FinishedAt__c   = now;
                r.AJO_DurationSec__c  = AJORunLogger.seconds(r.AJO_StartedAt__c, now);
                r.AJO_ErrorMessage__c = 'Exceeded ' + limitMins
                                    + ' minutes without completing. Released by the supervisor.';
                stuck.add(AJORunLogger.patch(r));
                jobIds.add(r.AJO_Job__c);
            }
        }
        if (stuck.isEmpty()) { return 0; }
        update stuck;

        List<AJOJob__c> jobs = [
            SELECT Id, AJO_Status__c FROM AJOJob__c WHERE Id IN :jobIds AND AJO_Status__c = 'Running'
        ];
        for (AJOJob__c j : jobs) { j.AJO_Status__c = 'Idle'; }
        if (!jobs.isEmpty()) { update jobs; }
        return stuck.size();
    }

    /**
     * Retires jobs whose End Date has passed.
     *
     * The dispatcher already refuses to launch them, so this is not what makes
     * the window safe — it is what makes the window visible. Without it a job
     * that stopped in March still reads as Idle in October, and nobody can tell
     * a finished ten-day task from one that is quietly broken.
     */
    public static Integer expireLapsed() {
        Date today = Date.today();
        List<AJOJob__c> lapsed = [
            SELECT Id, AJO_Status__c, AJO_NextRunAt__c, AJO_EndDate__c
            FROM   AJOJob__c
            WHERE  AJO_EndDate__c != null
              AND  AJO_EndDate__c < :today
              AND  AJO_Status__c NOT IN ('Expired', 'Running', 'Suspended')
            LIMIT  2000
        ];
        if (lapsed.isEmpty()) { return 0; }
        for (AJOJob__c j : lapsed) {
            j.AJO_Status__c    = 'Expired';
            j.AJO_NextRunAt__c = null;
        }
        update lapsed;
        return lapsed.size();
    }

    /**
      * Clears queued markers whose instant is long past.
      *
      * A deferred run normally clears its own marker. If the platform ever drops
      * the queueable, the marker would otherwise leave the console advertising a
      * run that is never coming — the console trusts this field to say "queued
      * and about to start".
      */
    public static Integer clearLapsedQueue() {
        Datetime cutoff = Datetime.now().addMinutes(-30);
        List<AJOJob__c> stale = [
            SELECT Id, AJO_Status__c, AJO_QueuedForAt__c
            FROM   AJOJob__c
            WHERE  AJO_QueuedForAt__c != null
              AND  AJO_QueuedForAt__c < :cutoff
            LIMIT  2000
        ];
        if (stale.isEmpty()) { return 0; }
        for (AJOJob__c j : stale) {
            j.AJO_QueuedForAt__c = null;
            if (j.AJO_Status__c == 'Queued') { j.AJO_Status__c = 'Idle'; }
        }
        update stale;
        return stale.size();
    }

    /** Retention. Without this the log reaches ~500 MB a year. */
    public static Integer purge() {
        Datetime okCutoff   = Datetime.now().addDays(-AJOConfig.retentionSuccessDays());
        Datetime failCutoff = Datetime.now().addDays(-AJOConfig.retentionFailureDays());

        List<AJOJobRun__c> old = [
            SELECT Id
            FROM   AJOJobRun__c
            WHERE  (AJO_Status__c IN ('Success', 'Skipped', 'Dry Run', 'Throttled')
                        AND CreatedDate < :okCutoff)
               OR  (AJO_Status__c IN ('Failed', 'Stuck') AND CreatedDate < :failCutoff)
            LIMIT  9000
        ];
        if (old.isEmpty()) { return 0; }
        delete old;
        Database.emptyRecycleBin(old);
        return old.size();
    }
}