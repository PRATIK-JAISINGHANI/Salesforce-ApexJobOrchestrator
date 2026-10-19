/**
 * A batch written so that every column on Apex Job Run fills in.
 *
 * Register THIS class on the job, not a Schedulable wrapper around it:
 *
 *     Apex class        AJOSampleBatch
 *     How it runs       Batch
 *     Records per batch 200            <- actually used, and recorded on the run
 *     Schedule          whatever you need
 *
 * Registered this way the framework calls Database.executeBatch itself, so it
 * owns the job id from the first instant. Wrap it in a Schedulable that calls
 * executeBatch internally and the framework only sees a method that returned:
 * Apex Job Id stays blank, Items Processed stays empty, and the run is marked
 * Success in about a tenth of a second while the batch has not started.
 *
 * Four things here are load-bearing. Copy all four into your own batches.
 *
 *  1. A public no-argument constructor. The framework instantiates by name with
 *     Type.newInstance(), and without one the console refuses to save the job.
 *  2. Database.Stateful, so the counters survive between chunks.
 *  3. Counting real records as they are handled.
 *  4. Reporting those counts from finish(). Without this the run shows what
 *     AsyncApexJob knows, and AsyncApexJob counts CHUNKS: ten thousand records
 *     at a scope of 200 reports "50". Step 4 is what makes Items Processed mean
 *     records.
 */
global class AJOSampleBatch implements Database.Batchable<SObject>, Database.Stateful {

    // Stateful: these accumulate across every chunk of the run.
    global Integer recordsProcessed = 0;
    global Integer recordsFailed    = 0;
    global List<String> firstErrors = new List<String>();

    private final String soql;

    /**
      * Required by the framework. Keep the default query harmless — this one
      * only reads — and put the real selection in your own copy.
      */
    global AJOSampleBatch() {
        // Bounded on purpose. Drop the LIMIT once this is doing real work — it is
        // here so the default cannot sweep an entire production table by accident.
        this('SELECT Id, Name FROM Account WHERE CreatedDate = LAST_N_DAYS:7 LIMIT 200');
    }

    /** Used by AJOSampleScheduler, which passes a query built from job parameters. */
    global AJOSampleBatch(String soql) {
        this.soql = soql;
    }

    global Database.QueryLocator start(Database.BatchableContext bc) {
        return Database.getQueryLocator(soql);
    }

    global void execute(Database.BatchableContext bc, List<SObject> scope) {
        List<SObject> toSave = new List<SObject>();

        for (SObject record : scope) {
            try {
                // ------------------------------------------------------------
                // Your work goes here. This sample only reads, so it is safe to
                // run in any org; add the field changes you need and put the
                // records into toSave.
                // ------------------------------------------------------------
                recordsProcessed++;
            } catch (Exception e) {
                recordsFailed++;
                if (firstErrors.size() < 5) {
                    firstErrors.add(String.valueOf(record.get('Id')) + ': ' + e.getMessage());
                }
            }
        }

        if (!toSave.isEmpty()) {
            // allOrNone = false, so one bad record does not discard the chunk.
            for (Database.SaveResult sr : Database.update(toSave, false)) {
                if (sr.isSuccess()) { continue; }
                recordsFailed++;
                recordsProcessed--;
                if (firstErrors.size() < 5) {
                    firstErrors.add(sr.getErrors()[0].getMessage());
                }
            }
        }
    }

    /**
      * Where the run record gets the truth.
      *
      * bc.getJobId() is the same AsyncApexJob id the framework recorded when it
      * launched this batch, so report() finds the open run and closes it with
      * real record counts. It also takes the run out of the reconciler's reach,
      * so nothing later overwrites these figures with the chunk count.
      *
      * Returning false simply means this batch was started by something other
      * than the orchestrator — running it by hand from anonymous Apex, say —
      * and there is no run record to update. That is not an error.
      */
    global void finish(Database.BatchableContext bc) {
        String summary = 'Processed ' + recordsProcessed + ' record(s), '
                       + recordsFailed + ' failed.';
        if (!firstErrors.isEmpty()) {
            summary += ' First error(s): ' + String.join(firstErrors, ' | ');
        }
        AJORunLogger.report(bc.getJobId(), recordsProcessed, recordsFailed, summary);
    }
}
