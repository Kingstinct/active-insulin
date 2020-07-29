//
//  ExtensionDelegate.swift
//  INsulin WatchKit Extension
//
//  Created by Robert Herber on 2020-07-24.
//  Copyright © 2020 Robert Herber. All rights reserved.
//

import WatchKit
import UserNotifications
import HealthKit;
import Combine;
import Intents;
import SwiftUI

class ExtensionDelegate: NSObject, WKExtensionDelegate, UNUserNotificationCenterDelegate {
  
  var query: HKQuery?;
  
  func handleUserActivity(_ userInfo: [AnyHashable : Any]?) {
    
  }
  
  func handle(_ userActivity: NSUserActivity) {
    
  }
  
  func handle(_ intent: INIntent, completionHandler: @escaping (INIntentResponse) -> Void) {
    
  }
  
  func applicationDidFinishLaunching() {
    UNUserNotificationCenter.current().delegate = self;
    // Define the custom actions.
    
    var snoozes = Array<UNNotificationAction>();
    
    if(AppState.current.snooze15Enabled){
      snoozes.append(UNNotificationAction(identifier: "SNOOZE_15",
                                          title: NSLocalizedString("snooze_15", comment: "Snooze 15 mins") ,
                                          options: []))
    }
    if(AppState.current.snooze30Enabled){
      snoozes.append(UNNotificationAction(identifier: "SNOOZE_30",
                                          title: NSLocalizedString("snooze_30", comment: "Snooze 30 mins"),
                                          options: []))
    }
    if(AppState.current.snooze60Enabled){
      snoozes.append(UNNotificationAction(identifier: "SNOOZE_60",
                                          title: NSLocalizedString("snooze_60", comment: "Snooze 1 hour"),
                                          options: []))
    }
    
    
    
    // Define the notification type
    let notificationCategory = UNNotificationCategory(identifier: "PEAK", actions: snoozes, intentIdentifiers: [], options: [.allowAnnouncement, .allowInCarPlay])
    
    Health.current.healthStore.getRequestStatusForAuthorization(toShare: [Health.current.insulinQuantityType], read: [Health.current.insulinObjectType, Health.current.activeEnergyObjectType]) { (status, error) in
      if(status == .unnecessary){
        DispatchQueue.main.async {
          AppState.current.objectWillChange.send()
          AppState.current.isHealthKitAuthorized = .authorized;
          // AppState.current.$isHealthKitAuthorized.append(true)
          let query = HKObserverQuery.init(sampleType: Health.current.insulinQuantityType, predicate: nil) { (query, handler, error) in
            self.onUpdatedInsulin(completionHandler: handler)
          }
          
          Health.current.healthStore.execute(query)
          self.query = query;
        }
      } else {
        Health.current.healthStore.requestAuthorization(toShare: [Health.current.insulinQuantityType], read: [Health.current.insulinObjectType, Health.current.activeEnergyObjectType]) { (status, error) in
          DispatchQueue.main.async {
            AppState.current.objectWillChange.send()
            if(status){
              AppState.current.isHealthKitAuthorized = .authorized;
              let query = HKObserverQuery.init(sampleType: Health.current.insulinQuantityType, predicate: nil) { (query, handler, error) in
                self.onUpdatedInsulin(completionHandler: handler)
              }
              
              Health.current.healthStore.execute(query)
              self.query = query;
            } else {
              AppState.current.isHealthKitAuthorized = .unauthorized;
            }
          }
        }
      }
    }
    
    
    // Register the notification type.
    let notificationCenter = UNUserNotificationCenter.current()
    notificationCenter.setNotificationCategories([notificationCategory])
    
    notificationCenter.getNotificationSettings { (settings) in
      if(settings.alertSetting == .enabled && settings.soundSetting == .enabled){
        
      } else {
        notificationCenter.requestAuthorization(options: [.alert, .sound]) { (success, error) in
          
        }
      }
    }
  }
  
  func updateRelevantShortcuts(data: [ChartPoint], completionHandler: @escaping () -> Void){
    Health.current.fetchTimelineIOB(limit: 100, callback: { (error, timeline) in
      if let timeline = timeline {
        var shortcuts = Array<INRelevantShortcut>();
        
        for (index, (date, iob)) in timeline.enumerated() {
          
          let nextIndex = index + 1
          let end = timeline.count > nextIndex ? timeline[nextIndex].0 - 1 : nil;
          
          let chartData = data.filter { (point) -> Bool in
            return point.date >= date.addHours(addHours: -1) && point.date <= date.addHours(addHours: 1)
          }
          
          let title = NSLocalizedString("insulin_on_board", comment: "Insulin on Board");
          
          let shortcut = INShortcut(userActivity: .displayIOBActivityType())
          
          let suggestedShortcut = INRelevantShortcut(shortcut: shortcut)
          suggestedShortcut.shortcutRole = .information
          
          let template = INDefaultCardTemplate(title: title)
          template.subtitle = iob.format(f: "0.1")
          if let image = ChartBuilder.getChartImage(vals: chartData, now: date, width: 50, chartHeight: 50) {
            template.image = INImage.create(image: image);
          }
          
          
          suggestedShortcut.watchTemplate = template
          suggestedShortcut.relevanceProviders = [INDateRelevanceProvider(start: date, end: end)]
          shortcuts.append(suggestedShortcut)
        }
        
        INRelevantShortcutStore.default.setRelevantShortcuts(shortcuts) { (error) in
          completionHandler();
        }
        
      } else {
        completionHandler();
      }
    });
  }
  
  
  func onUpdatedInsulin(completionHandler: @escaping () -> Void){
    if let complications = CLKComplicationServer.sharedInstance().activeComplications {
      for complication in complications {
        CLKComplicationServer.sharedInstance().reloadTimeline(for: complication)
      }
    }
    
    UNUserNotificationCenter.current().removeAllPendingNotificationRequests();
    
    FileManager.default.clearTmpDirectory();
    
    Health.current.fetchActiveInsulinChart(from: Date().addHours(addHours: -1), to: Date().addHours(addHours: 11)) { (error, data) in
      DispatchQueue.main.async {
        if let currentPoint = data.first(where: { (point) -> Bool in
          return point.date >= Date()
        }) {
          if(AppState.current.notifyOnInsulinPeakEnabled){
            if let max = data.max(by: { (arg0, arg1) -> Bool in
              return arg0.currentInsulin < arg1.currentInsulin;
            }) {
              if(max != data.first && max.date > Date()){
                let content = UNMutableNotificationContent();
                content.body = NSLocalizedString("notification_peak_description", comment: "notification_peak_description")
                content.subtitle = NSLocalizedString("insulin_on_board_short", comment: "IOB") + " - " + max.insulinOnBoard.format(f: "0.1")
                content.title = NSLocalizedString("notification_peak_title", comment: "notification_peak_title")
                content.sound = .default;
                let filteredData = data.filter { (point) -> Bool in
                  return point.date >= max.date.addHours(addHours: -1) && point.date <= max.date.addHours(addHours: 5)
                }
                if let image = ChartBuilder.getChartImage(vals: filteredData, now: max.date) {
                  content.attachments = [UNNotificationAttachment.create(image: image, options: .none )!]
                }
                content.categoryIdentifier = "PEAK";
                
                let dateMatching = Calendar.current.dateComponents([.minute, .day, .hour], from: max.date)
                let trigger = UNCalendarNotificationTrigger(dateMatching: dateMatching, repeats: false)
                UNUserNotificationCenter.current().add(UNNotificationRequest.init(identifier: "PEAK", content: content, trigger: trigger)) { (error) in
                  //something failed
                }
              }
            }
          }
          
          if(AppState.current.notifyOnInsulinZeroEnabled && currentPoint.insulinOnBoard > 0){
            if let point = data.first(where: { (point) -> Bool in
              return point.date >= Date() && point.insulinOnBoard == 0;
            }) {
              let content = UNMutableNotificationContent();
              content.body = NSLocalizedString("notification_zero_description", comment: "Zero Insulin")
              content.title = NSLocalizedString("notification_zero_title", comment: "notification_zero_title")
              content.sound = .default;
              let filteredData = data.filter { (point) -> Bool in
                return point.date >= point.date.addHours(addHours: -1) && point.date <= point.date.addHours(addHours: 5)
              }
              if let image = ChartBuilder.getChartImage(vals: filteredData, now: point.date) {
                content.attachments = [UNNotificationAttachment.create(image: image, options: .none )!]
              }
              content.categoryIdentifier = "PEAK";
              
              let dateMatching = Calendar.current.dateComponents([.minute, .day, .hour], from: point.date)
              let trigger = UNCalendarNotificationTrigger(dateMatching: dateMatching, repeats: false)
              UNUserNotificationCenter.current().add(UNNotificationRequest.init(identifier: "PEAK", content: content, trigger: trigger)) { (error) in
                //something failed
              }
            }
            
            
          }
        }
        
        
        
        
        
        //UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["PEAK"])
        
        
        
        
        
        if(AppState.current.notifyOnCustomEnabled){
          /*if let point = data.first(where: { (point) -> Bool in
           return point.date >= Date().addMinutes(addMinutes: AppState.current.notifyOnCustomMinutes);
           }) {
           let content = UNMutableNotificationContent();
           content.body = NSLocalizedString("notification_custom_description", comment: "Custom")
           content.subtitle = NSLocalizedString("insulin_on_board", comment: "IOB") + " - " + point.insulinOnBoard.format(f: "0.1")
           content.title = NSLocalizedString("notification_custom_title", comment: "notification_custom_title")
           content.sound = .default;
           let filteredData = data.filter { (point) -> Bool in
           return point.date >= point.date.addHours(addHours: -1) && point.date <= point.date.addHours(addHours: 5)
           }
           if let image = ChartBuilder.getChartImage(vals: filteredData, now: point.date) {
           content.attachments = [UNNotificationAttachment.create(image: image, options: .none )!]
           }
           content.categoryIdentifier = "PEAK";
           
           let dateMatching = Calendar.current.dateComponents([.minute, .day, .hour], from: point.date)
           let trigger = UNCalendarNotificationTrigger(dateMatching: dateMatching, repeats: false)
           UNUserNotificationCenter.current().add(UNNotificationRequest.init(identifier: "PEAK", content: content, trigger: trigger)) { (error) in
           //something failed
           }
           }
           */
          
        }
        
        self.updateRelevantShortcuts(data: data) {
          completionHandler();
        }
      }
      
      
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
      var minutesToAdd: Double;
      
      if(response.actionIdentifier == "SNOOZE_15"){
        minutesToAdd = 15;
      }
      else if(response.actionIdentifier == "SNOOZE_30"){
        minutesToAdd = 30;
      }
      else if(response.actionIdentifier == "SNOOZE_60"){
        minutesToAdd = 60;
      } else {
        completionHandler();
        return
      }
      let time = Date().addMinutes(addMinutes: minutesToAdd)
      
      Health.current.fetchActiveInsulinChart(from: Date().addHours(addHours: -1), to: Date().addHours(addHours: 6)) { (error, vals) in
        let content = UNMutableNotificationContent();
        content.body = NSLocalizedString("notification_snoozed_description", comment: "Snooze description");
        content.title = NSLocalizedString("notification_snoozed_title", comment: "Snooze title")
        content.categoryIdentifier = "PEAK";
        content.sound = .default;
        
        let currentVals = vals.filter { (point) -> Bool in
          return point.date >= time.addHours(addHours: -1) && point.date <= time.addHours(addHours: 5)
        }
        
        let dateMatching = Calendar.current.dateComponents([.minute, .day, .hour], from: time)
        let trigger = UNCalendarNotificationTrigger(dateMatching: dateMatching, repeats: false)
        if let image = ChartBuilder.getChartImage(vals: currentVals) {
          content.attachments = [UNNotificationAttachment.create(image: image, options: .none )!]
        }
        
        let atTime = vals.first { (point) -> Bool in
          return point.date >= time
        }
        
        if let iob = atTime?.insulinOnBoard {
          content.subtitle = NSLocalizedString("insulin_on_board_short", comment: "IOB") + " - " + iob.format(f: "0.1")
        }
        
        
        let request = UNNotificationRequest.init(identifier: "SNOOZE", content: content, trigger: trigger);
        
        UNUserNotificationCenter.current().add(request) { (error) in
          //something failed
        }
        
        completionHandler();
      }
      
      
      
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
      
    }
    
    func applicationDidBecomeActive() {
      UNUserNotificationCenter.current().removeAllDeliveredNotifications();
      Health.current.healthStore.getRequestStatusForAuthorization(toShare: [Health.current.insulinQuantityType], read: [Health.current.insulinObjectType, Health.current.activeEnergyObjectType]) { (status, error) in
        DispatchQueue.main.async {
          
          if(status == .unnecessary){
            AppState.current.objectWillChange.send()
            AppState.current.isHealthKitAuthorized = .authorized;
            if(self.query == nil){
              let query = HKObserverQuery.init(sampleType: Health.current.insulinQuantityType, predicate: nil) { (query, handler, error) in
                self.onUpdatedInsulin(completionHandler: handler)
              }
              
              Health.current.healthStore.execute(query)
              self.query = query;
            }
            
          } else {
            AppState.current.objectWillChange.send()
            AppState.current.isHealthKitAuthorized = .unauthorized;
          }
        }
      }
      // Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
    }
    
    func applicationWillResignActive() {
      // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
      // Use this method to pause ongoing tasks, disable timers, etc.
    }
    
    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
      /*
       
       WKInterfaceController.reloadRootPageControllers(withNames:
       ["Controller1" "Controller2", "Controller3"],
       contexts: [context1, context2, context3],
       orientation: WKPageOrientation.horizontal,
       pageIndex: 1)
       */
      // Sent when the system needs to launch the application in the background to process tasks. Tasks arrive in a set, so loop through and process each one.
      for task in backgroundTasks {
        // Use a switch statement to check the task type
        switch task {
        case let backgroundTask as WKApplicationRefreshBackgroundTask:
          onUpdatedInsulin {
            backgroundTask.setTaskCompletedWithSnapshot(true)
          }
        case let snapshotTask as WKSnapshotRefreshBackgroundTask:
          onUpdatedInsulin {
            snapshotTask.setTaskCompleted(restoredDefaultState: true, estimatedSnapshotExpiration: Date.distantFuture, userInfo: nil)
          }
          
        case let connectivityTask as WKWatchConnectivityRefreshBackgroundTask:
          // Be sure to complete the connectivity task once you’re done.
          connectivityTask.setTaskCompletedWithSnapshot(false)
        case let urlSessionTask as WKURLSessionRefreshBackgroundTask:
          // Be sure to complete the URL session task once you’re done.
          urlSessionTask.setTaskCompletedWithSnapshot(false)
        case let relevantShortcutTask as WKRelevantShortcutRefreshBackgroundTask:
          Health.current.fetchActiveInsulinChart(from: Date().addHours(addHours: -1), to: Date().addHours(addHours: 5)) { (error, data) in
            self.updateRelevantShortcuts(data: data) {
              relevantShortcutTask.setTaskCompletedWithSnapshot(false)
            }
          }
          
        case let intentDidRunTask as WKIntentDidRunRefreshBackgroundTask:
          // Be sure to complete the intent-did-run task once you're done.
          intentDidRunTask.setTaskCompletedWithSnapshot(false)
        default:
          // make sure to complete unhandled task types
          
          task.setTaskCompletedWithSnapshot(false)
        }
      }
    }
  }
}






