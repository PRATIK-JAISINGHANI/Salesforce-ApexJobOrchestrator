/** Exists to prove the circuit breaker. Fails every time, on purpose. */
global class AJODemoFailingJob implements Schedulable {
    global class DeliberateFailureException extends Exception {}
    global void execute(SchedulableContext sc) {
        throw new DeliberateFailureException(
            'This job fails deliberately, to demonstrate retry counting and auto-suspend.');
    }
}