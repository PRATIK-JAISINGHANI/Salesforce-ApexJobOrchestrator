/** A plain Queueable, enqueued by the orchestrator. */
public class AJODemoQueueable implements Queueable {
    public void execute(QueueableContext qc) {
        Integer n = [SELECT COUNT() FROM User WHERE IsActive = true];
        System.debug(LoggingLevel.INFO, 'AJODemoQueueable saw ' + n + ' active users.');
    }
}