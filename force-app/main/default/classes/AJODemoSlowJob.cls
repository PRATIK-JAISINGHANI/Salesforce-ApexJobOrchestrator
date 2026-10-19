/** A Batchable that yields several chunks, so throttling is observable. */
global class AJODemoSlowJob implements Database.Batchable<SObject> {
    global Database.QueryLocator start(Database.BatchableContext bc) {
        return Database.getQueryLocator([SELECT Id FROM User]);
    }
    global void execute(Database.BatchableContext bc, List<User> scope) {
        Long until = System.currentTimeMillis() + 1500;
        while (System.currentTimeMillis() < until) { /* occupy a batch slot briefly */ }
    }
    global void finish(Database.BatchableContext bc) {}
}