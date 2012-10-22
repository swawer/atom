#import <Cocoa/Cocoa.h>
#import <iostream>
#import "CocoaOniguruma/OnigRegexp.h"
#import "include/cef_base.h"
#import "include/cef_v8.h"
#import "onig_scanner.h"

namespace v8_extensions {

using namespace std;
extern NSString *stringFromCefV8Value(const CefRefPtr<CefV8Value>& value);

class OnigScannerUserData : public CefBase {
  public:
  OnigScannerUserData(CefRefPtr<CefV8Value> sources) {
    int length = sources->GetArrayLength();

    regExps.resize(length);
    cachedResults.resize(length);

    for (int i = 0; i < length; i++) {
      NSString *sourceString = stringFromCefV8Value(sources->GetValue(i));
      regExps[i] = [[OnigRegexp compile:sourceString] retain];
    }
  }

  ~OnigScannerUserData() {
    for (vector<OnigRegexp *>::iterator iter = regExps.begin(); iter < regExps.end(); iter++) {
      [*iter release];
    }
    for (vector<OnigResult *>::iterator iter = cachedResults.begin(); iter < cachedResults.end(); iter++) {
      [*iter release];
    }
  }

  CefRefPtr<CefV8Value> FindNextMatch(CefRefPtr<CefV8Value> v8String, CefRefPtr<CefV8Value> v8StartLocation) {

    std::string string = v8String->GetStringValue().ToString();
    int startLocation = v8StartLocation->GetIntValue();
    int bestIndex = -1;
    int bestLocation = NULL;
    OnigResult *bestResult = NULL;

    bool useCachedResults = (string == lastMatchedString && startLocation >= lastStartLocation);
    lastStartLocation = startLocation;

    if (!useCachedResults) {
      ClearCachedResults();
      lastMatchedString = string;
    }

    vector<OnigRegexp *>::iterator iter = regExps.begin();
    int index = 0;
    while (iter < regExps.end()) {
      OnigRegexp *regExp = *iter;

      bool useCachedResult = false;
      OnigResult *result = NULL;
      
      // In Oniguruma, \G is based on the start position of the match, so the result
      // changes based on the start position. So it can't be cached.
      BOOL containsBackslashG = [regExp.expression rangeOfString:@"\\G"].location != NSNotFound;
      if (useCachedResults && index <= maxCachedIndex && ! containsBackslashG) {
        result = cachedResults[index];
        useCachedResult = (result == NULL || [result locationAt:0] >= startLocation);
      }

      if (!useCachedResult) {
        result = [regExp search:[NSString stringWithUTF8String:string.c_str()] start:startLocation];
        cachedResults[index] = [result retain];
        maxCachedIndex = index;
      }

      if ([result count] > 0) {
        int location = [result locationAt:0];
        if (bestIndex == -1 || location < bestLocation) {
          bestLocation = location;
          bestResult = result;
          bestIndex = index;
        }

        if (location == startLocation) {
          break;
        }
      }

      iter++;
      index++;
    }

    if (bestIndex >= 0) {
      CefRefPtr<CefV8Value> result = CefV8Value::CreateObject(NULL);
      result->SetValue("index", CefV8Value::CreateInt(bestIndex), V8_PROPERTY_ATTRIBUTE_NONE);
      result->SetValue("captureIndices", CaptureIndicesForMatch(bestResult), V8_PROPERTY_ATTRIBUTE_NONE);
      return result;
    } else {
      return CefV8Value::CreateNull();
    }
  }

  void ClearCachedResults() {
    maxCachedIndex = -1;
    for (vector<OnigResult *>::iterator iter = cachedResults.begin(); iter < cachedResults.end(); iter++) {
      [*iter release];
      *iter = NULL;
    }
  }

  CefRefPtr<CefV8Value> CaptureIndicesForMatch(OnigResult *result) {
    CefRefPtr<CefV8Value> array = CefV8Value::CreateArray([result count] * 3);
    int i = 0;
    int resultCount = [result count];
    for (int index = 0; index < resultCount; index++) {
      int captureLength = [result lengthAt:index];
      int captureStart = [result locationAt:index];

      array->SetValue(i++, CefV8Value::CreateInt(index));
      array->SetValue(i++, CefV8Value::CreateInt(captureStart));
      array->SetValue(i++, CefV8Value::CreateInt(captureStart + captureLength));
    }

    return array;
  }

  protected:
  std::vector<OnigRegexp *> regExps;
  std::string lastMatchedString;
  std::vector<OnigResult *> cachedResults;
  int maxCachedIndex;
  int lastStartLocation;

  IMPLEMENT_REFCOUNTING(OnigRegexpUserData);
};

OnigScanner::OnigScanner() : CefV8Handler() {
  NSString *filePath = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"v8_extensions/onig_scanner.js"];
  NSString *extensionCode = [NSString stringWithContentsOfFile:filePath encoding:NSUTF8StringEncoding error:nil];
  CefRegisterExtension("v8/onig-scanner", [extensionCode UTF8String], this);
}


bool OnigScanner::Execute(const CefString& name,
                         CefRefPtr<CefV8Value> object,
                         const CefV8ValueList& arguments,
                         CefRefPtr<CefV8Value>& retval,
                         CefString& exception) {
  if (name == "findNextMatch") {
    OnigScannerUserData *userData = (OnigScannerUserData *)object->GetUserData().get();
    retval = userData->FindNextMatch(arguments[0], arguments[1]);
    return true;
  }
  else if (name == "buildScanner") {
    retval = CefV8Value::CreateObject(NULL);
    retval->SetUserData(new OnigScannerUserData(arguments[0]));
    return true;
  }

  return false;
}

} // namespace v8_extensions