//=============================================================================
//   MuseScore 4 Plugin
//   Custom Note Colors Generator
//=============================================================================

import QtQuick 2.0
import MuseScore 4.0

MuseScore {
      version:  "1.0"
      description: qsTr("This plugin colours notes in the selection depending on their pitch.")
      menuPath: "Plugins.Notes.Custom Note Colours 1"

      property variant colors : [ 
                     "#ff0000", // C
                     "#ff3300", // C#
                     "#ff7824", // D
                     "#ffa530", // D#
                     "#ffd324", // E
                     "#8cff00", // F
                     "#00c254", // F#
                     "#007d4f", // G
                     "#005de8", // G#
                     "#17009c", // A
                     "#7134b3", // A#
                     "#c114c7"  // B
                    ]

      function applyToNotesInSelection(func) {
            var cursor = curScore.newCursor();
            cursor.rewind(1);
            var startStaff;
            var endStaff;
            var endTick;
            var fullScore = false;
            
            if (!cursor.segment) { // no selection
                  fullScore = true;
                  startStaff = 0; 
                  endStaff = curScore.nstaves - 1; 
            } else {
                  startStaff = cursor.staffIdx;
                  cursor.rewind(2);
                  if (cursor.tick === 0) {
                        endTick = curScore.lastSegment.tick + 1;
                  } else {
                        endTick = cursor.tick;
                  }
                  endStaff = cursor.staffIdx;
            }
            
            for (var staff = startStaff; staff <= endStaff; staff++) {
                  for (var voice = 0; voice < 4; voice++) {
                        cursor.rewind(1); 
                        cursor.voice = voice; 
                        cursor.staffIdx = staff;

                        if (fullScore)
                              cursor.rewind(0);

                        while (cursor.segment && (fullScore || cursor.tick < endTick)) {
                              if (cursor.element && cursor.element.type === Element.CHORD) {
                                    var graceChords = cursor.element.graceNotes;
                                    for (var i = 0; i < graceChords.length; i++) {
                                          var graceNotes = graceChords[i].notes;
                                          for (var j = 0; j < graceNotes.length; j++)
                                                func(graceNotes[j]);
                                    }
                                    var notes = cursor.element.notes;
                                    for (var k = 0; k < notes.length; k++) {
                                          func(notes[k]);
                                    }
                              }
                              cursor.next();
                        }
                  }
            }
      }

      function colorNote(note) {
            var targetColor = colors[note.pitch % 12];
            
            // Force apply custom color to the notehead
            note.color = targetColor;

            // Force apply to accidentals if present
            if (note.accidental) {
                  note.accidental.color = targetColor;
            }

            // Force apply to dots
            for (var i = 0; i < note.dots.length; i++) {
                  if (note.dots[i]) {
                        note.dots[i].color = targetColor;
                  }
            }
      }

      onRun: {
            if (typeof curScore === 'undefined')
                  Qt.quit();

            applyToNotesInSelection(colorNote);

            Qt.quit();
      }
}