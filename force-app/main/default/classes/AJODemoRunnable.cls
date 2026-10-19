/**
 * A job written against the framework rather than adapted to it.
 * It receives configuration through the context, so one class can back many
 * configured jobs, and it reports its own counters into the run record.
 */
public with sharing class AJODemoRunnable implements AJORunnable {

    public void run(AJOContext ctx) {
        String objectName = ctx.getString('object', 'User');
        Integer target    = ctx.getInteger('target', 0);

        Integer count;
        if (objectName == 'Account') {
            count = [SELECT COUNT() FROM Account];
        } else if (objectName == 'Contact') {
            count = [SELECT COUNT() FROM Contact];
        } else {
            count = [SELECT COUNT() FROM User WHERE IsActive = true];
        }

        ctx.itemsProcessed = count;
        ctx.itemsFailed    = (target > 0 && count < target) ? 1 : 0;
        ctx.message = 'Counted ' + count + ' ' + objectName + ' records'
                    + (target > 0 ? ' against a target of ' + target : '')
                    + '. Job key ' + ctx.jobKey
                    + ', triggered by ' + ctx.triggeredBy + '.';
    }
}