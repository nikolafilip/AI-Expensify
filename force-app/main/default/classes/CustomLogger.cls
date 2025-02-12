public class CustomLogger {
    public enum LogLevel {
        INFO,
        WARN,
        ERROR
    }

    private static final String LOG_OBJECT = 'System_Log__c';
    private static List<System_Log__c> pendingLogs = new List<System_Log__c>();
    private static Boolean isQueueableScheduled = false;

    public static void logInfo(String message) {
        log(LogLevel.INFO, message, null, null);
    }

    public static void logInfo(String message, Map<String, Object> context) {
        log(LogLevel.INFO, message, context, null);
    }

    public static void logWarn(String message) {
        log(LogLevel.WARN, message, null, null);
    }

    public static void logWarn(String message, Map<String, Object> context) {
        log(LogLevel.WARN, message, context, null);
    }

    public static void logError(String message, Exception e) {
        log(LogLevel.ERROR, message, null, e);
    }

    public static void logError(String message, Map<String, Object> context, Exception e) {
        log(LogLevel.ERROR, message, context, e);
    }

    private static void log(LogLevel level, String message, Map<String, Object> context, Exception e) {
        String contextJson = context != null ? JSON.serialize(context) : null;
        String stackTrace = e != null ? e.getStackTraceString() : null;
        String errorType = e != null ? e.getTypeName() : null;

        String logMessage = String.format(
            'Level: {0}\nMessage: {1}\nContext: {2}\nError Type: {3}\nStack Trace: {4}',
            new List<String>{
                level.name(),
                message,
                contextJson,
                errorType,
                stackTrace
            }
        );
        
        System_Log__c log = new System_Log__c(
            Log_Level__c = level.name(),
            Message__c = message,
            Context__c = contextJson,
            Error_Type__c = errorType,
            Stack_Trace__c = stackTrace,
            Timestamp__c = Datetime.now()
        );

        pendingLogs.add(log);
        
        // If we're not in a future or queueable context, schedule the queueable
        if (!System.isFuture() && !System.isQueueable() && !isQueueableScheduled) {
            System.enqueueJob(new LogInsertQueueable(pendingLogs));
            pendingLogs = new List<System_Log__c>();
            isQueueableScheduled = true;
        }
    }

    public class LogInsertQueueable implements System.Queueable {
        private List<System_Log__c> logs;
        
        public LogInsertQueueable(List<System_Log__c> logs) {
            this.logs = logs;
        }
        
        public void execute(System.QueueableContext context) {
            if (logs != null && !logs.isEmpty()) {
                insert logs;
            }
            isQueueableScheduled = false;
        }
    }
} 