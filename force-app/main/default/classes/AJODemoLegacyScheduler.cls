/**
 * Deliberately written the way the 89 Schedulable classes in the source production org are
 * written: it ignores the SchedulableContext it is handed. That is what lets
 * the adapter pass null and leave the class untouched.
 */
global class AJODemoLegacyScheduler implements Schedulable {
    global void execute(SchedulableContext sc) {
        Integer users = [SELECT COUNT() FROM User WHERE IsActive = true];
        System.debug(LoggingLevel.INFO,
            'AJODemoLegacyScheduler ran synchronously. Active users: ' + users);
    }
}