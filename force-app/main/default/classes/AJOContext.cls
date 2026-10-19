/** Everything a Runnable job is told about the run it is part of. */
public with sharing class AJOContext {

    public Id jobId          { get; private set; }
    public Id runId          { get; private set; }
    public String jobKey     { get; private set; }
    public Datetime scheduledFor { get; private set; }
    public String triggeredBy    { get; private set; }

    /** Parsed from AJOJob__c.AJO_Parameters__c. Empty map when unset or unparseable. */
    public Map<String, Object> params { get; private set; }

    /** A Runnable writes its own counters and summary here; the logger picks them up. */
    public Integer itemsProcessed { get; set; }
    public Integer itemsFailed    { get; set; }
    public String  message        { get; set; }

    /**
      * Set this when the job starts async work of its own, and the run record
      * stops lying about it.
      *
      * A class that launches a batch and returns used to look instantaneous: the
      * launcher saw a synchronous return, wrote Success and a tenth of a second,
      * and never recorded the batch's id — so Apex Job Id was blank and Items
      * Processed stayed empty while the real work was still running. Hand the id
      * back here and the run stays open until the platform finishes, exactly as
      * a directly registered Batch job does.
      */
    public Id asyncJobId { get; set; }

    /** The scope handed to Database.executeBatch, recorded on the run record. */
    public Integer batchSize { get; set; }

    /** The job's configured Records Per Batch, so a Runnable can honour it. */
    public Integer configuredBatchSize { get; private set; }

    public AJOContext(AJOJob__c job, AJOJobRun__c run) {
        this.jobId        = job.Id;
        this.runId        = run != null ? run.Id : null;
        this.jobKey       = job.AJO_JobKey__c;
        this.scheduledFor = run != null ? run.AJO_ScheduledFor__c : job.AJO_NextRunAt__c;
        this.triggeredBy  = run != null ? run.AJO_TriggeredBy__c : 'Heartbeat';
        this.params       = parseParams(job.AJO_Parameters__c);
        this.itemsProcessed = 0;
        this.itemsFailed    = 0;
        this.message        = null;
        this.asyncJobId     = null;
        this.batchSize      = null;
        this.configuredBatchSize = job.AJO_BatchSize__c == null
                                   ? null : job.AJO_BatchSize__c.intValue();
    }

    private static Map<String, Object> parseParams(String raw) {
        if (String.isBlank(raw)) { return new Map<String, Object>(); }
        try {
            Object o = JSON.deserializeUntyped(raw);
            return (o instanceof Map<String, Object>)
                   ? (Map<String, Object>) o
                   : new Map<String, Object>();
        } catch (Exception e) {
            return new Map<String, Object>();
        }
    }

    public String getString(String key, String fallback) {
        Object v = params.get(key);
        return v == null ? fallback : String.valueOf(v);
    }

    public Integer getInteger(String key, Integer fallback) {
        Object v = params.get(key);
        if (v == null) { return fallback; }
        try { return Integer.valueOf(String.valueOf(v)); }
        catch (Exception e) { return fallback; }
    }

    public Boolean getBoolean(String key, Boolean fallback) {
        Object v = params.get(key);
        if (v == null) { return fallback; }
        return String.valueOf(v) == 'true';
    }
}