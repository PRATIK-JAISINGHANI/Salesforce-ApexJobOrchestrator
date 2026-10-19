/**
 * Keeps the org below the platform's five-concurrent-batch ceiling instead of
 * discovering it. This is the capability the platform never offered: today
 * 43 of the source production org's live jobs all fire at :00 and the winners are arbitrary.
 */
public with sharing class AJOThrottle {

    private Integer batchBudget;

    public AJOThrottle() {
        this.batchBudget = availableBatchSlots();
    }

    public static Integer inFlightBatches() {
        return [
            SELECT COUNT()
            FROM   AsyncApexJob
            WHERE  JobType = 'BatchApex'
              AND  Status IN ('Holding', 'Queued', 'Preparing', 'Processing')
        ];
    }

    public static Integer availableBatchSlots() {
        return Math.max(0, AJOConfig.maxConcurrentBatches() - inFlightBatches());
    }

    /** True when this job may start now. Consumes budget for batch work. */
    public Boolean claim(AJOJob__c job) {
        if (job.AJO_ExecutionType__c != 'Batch') { return true; }
        if (batchBudget <= 0) { return false; }
        batchBudget--;
        return true;
    }

    public Integer remaining() { return batchBudget; }
}