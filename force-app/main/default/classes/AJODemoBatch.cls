/** A plain Batchable, launched by the orchestrator with a configured scope. */
global class AJODemoBatch implements Database.Batchable<SObject>, Database.Stateful {

    global Integer processed = 0;

    /**
      * Bounded on purpose. This is a demonstration job, and an unbounded locator
      * over a real org's user table is both pointless and untestable: with 2,885
      * active users and a scope of 200 the platform makes fifteen execute()
      * calls, and a test method is allowed exactly one.
      */
    global Database.QueryLocator start(Database.BatchableContext bc) {
        return Database.getQueryLocator(
            [SELECT Id, Name FROM User WHERE IsActive = true LIMIT 200]);
    }

    global void execute(Database.BatchableContext bc, List<User> scope) {
        processed += scope.size();
    }

    global void finish(Database.BatchableContext bc) {
        System.debug(LoggingLevel.INFO, 'AJODemoBatch processed ' + processed + ' records.');
    }
}