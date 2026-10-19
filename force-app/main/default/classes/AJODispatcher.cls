/**
 * The heartbeat. Six of these hold six of the org's 100 scheduled Apex slots
 * and between them carry an unlimited number of configured jobs.
 *
 *   0 0  * * * ?    slot 0
 *   0 10 * * * ?    slot 10
 *   0 20 * * * ?    slot 20   ... and so on to slot 50
 */
global with sharing class AJODispatcher implements Schedulable {

    global Integer slotMinute;

    global AJODispatcher() { this.slotMinute = 0; }

    global AJODispatcher(Integer slotMinute) { this.slotMinute = slotMinute; }

    global void execute(SchedulableContext sc) {
        run(slotMinute);
    }

    public static Integer run(Integer slot) {
        if (AJOConfig.killSwitch()) {
            return 0;
        }

        // Close out async work started by an earlier heartbeat before deciding
        // what is due — otherwise an overlap check reads a stale 'Running'.
        try {
            AJORunLogger.reconcile();
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'AJO reconcile failed: ' + e.getMessage());
        }

        Datetime windowEnd = Datetime.now().addMinutes(AJOConfig.heartbeatMinutes());

        // The activation window is filtered here rather than read from
        // AJO_IsActive__c: the formula field is not indexed and this query has to
        // stay selective as the job count grows.
        List<AJOJob__c> due = Database.query(
            'SELECT ' + AJOLauncher.JOB_FIELDS + ' FROM AJOJob__c '
            + 'WHERE ' + AJOWindow.SOQL_FILTER
            + '  AND AJO_Pinned__c = false '
            + '  AND AJO_Status__c NOT IN (\'Suspended\', \'Expired\') '
            + '  AND AJO_NextRunAt__c != null '
            + '  AND AJO_NextRunAt__c <= :windowEnd '
            + 'ORDER BY AJO_Priority__c ASC NULLS LAST, AJO_NextRunAt__c ASC '
            + 'LIMIT 200');

        AJOLauncher.launch(due, slot);
        return due.size();
    }
}