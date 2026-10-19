/**
 * The scheduler-shaped job, written so the run record still captures everything.
 *
 *     Apex class        AJOSampleScheduler
 *     How it runs       Written for this framework      (Runnable)
 *     Records per batch 200
 *     Settings (JSON)   {"object":"Account","days":7,"limit":0}
 *     Schedule          whatever you need
 *
 * Use this shape when the job has to do something before the batch starts —
 * pick records, flip statuses, decide whether to run at all — which is exactly
 * what a classic Schedulable wrapper does.
 *
 * Why not just register the existing Schedulable? Because of how the framework
 * sees it. A Schedulable is called, it calls Database.executeBatch internally,
 * and it returns. All the framework observes is a method that returned, so:
 *
 *     Apex Job Id        blank      - it never saw the batch id
 *     Items Processed    blank      - nothing to reconcile against
 *     Records Per Batch  blank      - the class chose its own scope, not the job's
 *     Duration           ~0.1s      - the time to START the work
 *     Status             Success    - recorded before the batch had begun
 *
 * Implementing AJORunnable instead gives you one extra thing a Schedulable
 * cannot have: somewhere to hand the batch id back. Set ctx.asyncJobId and the
 * framework keeps the run open until the platform finishes it, so the run shows
 * the real duration and the real outcome instead of "Success" at launch.
 *
 * A legacy Schedulable is still fine for work that finishes inline. This is only
 * for one that starts async work.
 */
public with sharing class AJOSampleScheduler implements AJORunnable {

    public void run(AJOContext ctx) {

        // ---- 1. the pre-work a scheduler normally does ----------------------
        // ctx.params is the Settings (JSON) field on the job, so one class can
        // back several jobs with different configuration.
        String objectName = ctx.getString('object', 'Account');
        Integer days      = ctx.getInteger('days', 7);
        // 0 means no cap. Worth setting: an unbounded locator over a large table
        // makes one execute() call per chunk, and a test method is allowed
        // exactly one — so a job that passes in a small org fails in a big one.
        Integer cap       = ctx.getInteger('limit', 0);

        String fromClause = ' FROM ' + String.escapeSingleQuotes(objectName);
        String dateFilter = ' WHERE CreatedDate = LAST_N_DAYS:' + days;
        String capClause  = cap > 0 ? ' LIMIT ' + cap : '';

        String soql = 'SELECT Id, Name' + fromClause + dateFilter + capClause;

        // Decide whether there is anything to do before starting a batch at all.
        Integer waiting = Database.countQuery(
            'SELECT COUNT()' + fromClause + dateFilter + capClause);

        if (waiting == 0) {
            // Nothing to do. Say so plainly rather than launching an empty batch:
            // the run closes as Success with a message that explains itself, and
            // no Apex Job Id because no async work was started. A run that did
            // nothing should look different from one that did something.
            ctx.itemsProcessed = 0;
            ctx.message = 'Nothing waiting in ' + objectName
                        + ' for the last ' + days + ' day(s); no batch started.';
            return;
        }

        // ---- 2. honour the job's configured Records Per Batch ---------------
        // This is the part a legacy Schedulable always got wrong: it hardcoded
        // its own scope, so the value on the job record meant nothing.
        Integer scope = ctx.configuredBatchSize == null ? 200 : ctx.configuredBatchSize;

        // ---- 3. launch, and hand the id back --------------------------------
        Id batchId = Database.executeBatch(new AJOSampleBatch(soql), scope);

        ctx.asyncJobId = batchId;   // keeps the run open until the batch finishes
        ctx.batchSize  = scope;     // recorded on the run as Records Per Batch
        ctx.message    = 'Started ' + objectName + ' batch over ' + waiting
                       + ' record(s) at ' + scope + ' per batch.';

        // Do not set ctx.itemsProcessed here — the batch itself reports the real
        // counts from its finish() method, and anything set here would be
        // replaced by figures that are actually true.
    }
}
