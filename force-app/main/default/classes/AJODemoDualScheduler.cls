/**
 * The awkward shape: implements BOTH Schedulable and Batchable, and picks its
 * own scope size inside execute(). Ten classes in the source production org look like this.
 *
 * If the adapter tested Batchable first it would start the batch with the
 * configured scope instead of the 50 this class chose — a silent behaviour
 * change in production. Testing Schedulable first reproduces the platform.
 */
global class AJODemoDualScheduler implements Schedulable, Database.Batchable<SObject> {

    global void execute(SchedulableContext sc) {
        // The scope size is this class's decision, not the configuration's.
        Database.executeBatch(new AJODemoDualScheduler(), 50);
    }

    // Bounded to the scope this class picks for itself above, so it is one
    // chunk in any org. See the note in AJODemoBatch.
    global Database.QueryLocator start(Database.BatchableContext bc) {
        return Database.getQueryLocator(
            [SELECT Id FROM User WHERE IsActive = true LIMIT 50]);
    }

    global void execute(Database.BatchableContext bc, List<User> scope) {
        System.debug(LoggingLevel.INFO,
            'AJODemoDualScheduler batch chunk of ' + scope.size());
    }

    global void finish(Database.BatchableContext bc) {
        System.debug(LoggingLevel.INFO, 'AJODemoDualScheduler finished.');
    }
}